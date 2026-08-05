import 'dart:convert';
import '../analysis/providers.dart';
import '../analysis/segmentation_builder.dart';
import '../log/app_log.dart';
import 'ark_chat_client.dart';

/// 语义分组降级的原因（LLM 输出不可用，退回「每句一个台词语义单元」）
enum SemanticSplitDegradation {
  /// 输出根本不是约定格式（模型答非所问、被截断、夹带解释文字等）
  unparsableOutput,

  /// 输出能读出来但不是合法分组（跳句、重排、遗漏、索引越界）
  invalidPartition;

  /// 面向用户的中文说明，上层可直接展示，不含技术黑话
  String get userMessage => switch (this) {
        SemanticSplitDegradation.unparsableOutput =>
          'AI 未按约定格式返回语义分组，已退回按每句台词切一个语义单元，'
              '可在时间线上手动合并',
        SemanticSplitDegradation.invalidPartition =>
          'AI 返回的语义分组不完整（有跳句或重复），已退回按每句台词切一个语义单元，'
              '可在时间线上手动合并',
      };
}

/// 降级通知：分组降级时同步回调一次。
///
/// [SemanticSplitter] 接口只返回单元列表，降级与否从结果里看不出来——用户拿到
/// 一堆碎片单元只会以为「AI 就这水平」。上层接上这个回调后可以明确告诉用户
/// 这是降级结果。
typedef SemanticSplitDegradationCallback = void Function(
    SemanticSplitDegradation reason);

/// LLM 语义分组（句子索引协议）：模型只分组，不产时间戳——边界由代码从句子时间戳推导
class VolcanoSemanticSplitter implements SemanticSplitter {
  final ArkChatClient chat;

  /// 用 mini 而不是默认的 lite。
  ///
  /// 同一批 27 句 ASR 实测：lite-260215 要 **39.4 秒**、mini-260428 只要
  /// **9.0 秒**（4.4 倍），而切分结果 mini 反而更贴——那一次 lite 漏了两刀，
  /// mini 切出的 7 个单元起点几乎与人工认可的结果重合。
  ///
  /// 这一步在关键路径上（打标必须等它），39 秒是等待时间里的第二大头。
  ///
  /// **注意**：大模型不是确定性的，同一个模型同样的输入两次结果都可能不同
  /// （基准那次 lite 切 7 个，复测切 5 个）。所以这里不能用「与基准逐字一致」
  /// 当验收标准，只能看切得合不合理。
  static const String model = 'doubao-seed-2-0-mini-260428';

  /// 可选：降级通知出口，不接则只写日志（行为与接之前一致）
  final SemanticSplitDegradationCallback? onDegraded;

  /// 采样温度。**默认 0**：把一段台词分成几组是判断题，不是创作题。
  /// 不给这个值时用服务端默认（多半 1.0），实测同一条片子的切分结果
  /// 在 5~14 个单元之间跳——用户重跑一次分析，切分就变一个样。
  final double temperature;

  VolcanoSemanticSplitter(
      {required this.chat, this.onDegraded, this.temperature = 0});

  static const _systemPrompt = '''
你是短视频广告的台词语义切分专家。台词语义单元的定义：一段表达完整语义的台词（可能一句或多句），
如"痛点引入""产品介绍""功效演示""价格机制""行动号召"等各为一个单元。

规则：
1. 只能按给出的句子顺序分组，不得跳句、不得重排、不得遗漏任何句子索引
2. **按脚本的大结构分组，不要按小意群拆**：整条片子通常只有 5~8 个单元。
   宁可粗不可细——一个卖点讲三句话，那三句就是一个单元，不要拆成三个
3. 相邻的同语义句子合为一个单元；只在讲述目的真正转换时才切开
4. 只输出 JSON，不要任何解释或 markdown 标记

输出格式：{"units":[{"sentenceIndexes":[0,1]},{"sentenceIndexes":[2]}]}''';

  @override
  Future<List<UnitDraft>> split(List<AsrSentence> sentences) async {
    if (sentences.isEmpty) return const [];
    final numbered = [
      for (var i = 0; i < sentences.length; i++)
        {'index': i, 'text': sentences[i].text},
    ];
    final content = await chat.chatText(
      system: _systemPrompt,
      user: '句子列表：\n${jsonEncode(numbered)}',
      model: model,
      temperature: temperature,
    );
    return parseGrouping(content, sentences, onDegraded: onDegraded);
  }

  /// 解析并校验分组；任何不合法整体回退「每句一单元」，并通过 [onDegraded] 上报
  static List<UnitDraft> parseGrouping(
      String content, List<AsrSentence> sentences,
      {SemanticSplitDegradationCallback? onDegraded}) {
    final groups = _tryParseIndexGroups(content);
    if (groups == null) {
      return _degradeToOneUnitPerSentence(
          sentences, SemanticSplitDegradation.unparsableOutput, onDegraded);
    }
    if (!_isValidPartition(groups, sentences.length)) {
      return _degradeToOneUnitPerSentence(
          sentences, SemanticSplitDegradation.invalidPartition, onDegraded);
    }
    return List.unmodifiable([
      for (final g in groups)
        UnitDraft(
          startMs: sentences[g.first].startMs,
          endMs: sentences[g.last].endMs,
          transcript: [for (final i in g) sentences[i].text].join(),
        ),
    ]);
  }

  /// 降级路径：每句台词各成一个语义单元，同时写日志并通知上层
  static List<UnitDraft> _degradeToOneUnitPerSentence(
      List<AsrSentence> sentences,
      SemanticSplitDegradation reason,
      SemanticSplitDegradationCallback? onDegraded) {
    AppLog.warn('语义分组降级（${reason.name}）：${reason.userMessage}');
    onDegraded?.call(reason);
    return List.unmodifiable([
      for (final s in sentences)
        UnitDraft(startMs: s.startMs, endMs: s.endMs, transcript: s.text),
    ]);
  }

  static List<List<int>>? _tryParseIndexGroups(String content) {
    var text = content.trim();
    final fence = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$');
    final m = fence.firstMatch(text);
    if (m != null) text = m.group(1)!;
    try {
      final json = jsonDecode(text) as Map<String, dynamic>;
      final units = json['units'] as List<dynamic>;
      return [
        for (final u in units)
          ((u as Map<String, dynamic>)['sentenceIndexes'] as List<dynamic>)
              .map((e) => (e as num).toInt())
              .toList(),
      ];
    } catch (_) {
      return null;
    }
  }

  /// 校验：非空组、索引全体连续覆盖 0..n-1 且不重不漏、组内递增
  static bool _isValidPartition(List<List<int>> groups, int total) {
    final flat = <int>[];
    for (final g in groups) {
      if (g.isEmpty) return false;
      flat.addAll(g);
    }
    if (flat.length != total) return false;
    for (var i = 0; i < flat.length; i++) {
      if (flat[i] != i) return false;
    }
    return true;
  }
}
