import 'dart:convert';
import '../analysis/providers.dart';
import '../analysis/segmentation_builder.dart';
import '../log/app_log.dart';
import 'ark_chat_client.dart';
import 'grouping_repair.dart';

/// 语义分组降级的原因（LLM 输出不可用，退回「每句一个台词语义单元」）
enum SemanticSplitDegradation {
  /// 输出根本不是约定格式（模型答非所问、被截断、夹带解释文字等）
  unparsableOutput,

  /// 输出能读出来但不是合法分组（跳句、重排、遗漏、索引越界），且连
  /// 一个可用的切点都取不到——这才真的没救
  invalidPartition,

  /// 分组有瑕疵，但模型给的切点还在，已据此重建成合法分组。
  /// 这不是「退回一句一个」，结果仍然是像样的语义分段
  repairedPartition;

  /// 面向用户的中文说明，上层可直接展示，不含技术黑话
  String get userMessage => switch (this) {
        SemanticSplitDegradation.unparsableOutput =>
          'AI 未按约定格式返回语义分组，已退回按每句台词切一个语义单元，'
              '可在时间线上手动合并',
        SemanticSplitDegradation.invalidPartition =>
          'AI 返回的语义分组完全不可用，已退回按每句台词切一个语义单元，'
              '可在时间线上手动合并',
        SemanticSplitDegradation.repairedPartition =>
          'AI 返回的语义分组有跳句或重复，已按它给出的分段位置补齐，'
              '个别语义单元的边界可在时间线上微调',
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
  static const String defaultModel = 'doubao-seed-2-0-mini-260428';

  /// 实际用哪个模型。可覆盖是为了能拿同一批句子横向测各模型的分组合法率
  /// ——「切分不稳」到底是模型的问题还是提示词的问题，只能这么分辨
  final String model;

  /// 可选：降级通知出口，不接则只写日志（行为与接之前一致）
  final SemanticSplitDegradationCallback? onDegraded;

  /// 采样温度。**默认 0**：把一段台词分成几组是判断题，不是创作题。
  /// 不给这个值时用服务端默认（多半 1.0），实测同一条片子的切分结果
  /// 在 5~14 个单元之间跳——用户重跑一次分析，切分就变一个样。
  final double temperature;

  VolcanoSemanticSplitter(
      {required this.chat,
      this.onDegraded,
      this.temperature = 0,
      this.model = defaultModel});

  static const _systemPrompt = '''
你是短视频广告的台词语义切分专家。台词语义单元的定义：一段表达完整语义的台词（可能一句或多句），
如"痛点引入""产品介绍""功效演示""价格机制""行动号召"等各为一个单元。

你的任务是**指出每个单元从第几句开始**，不需要列出单元里的每一句——
从一个起点到下一个起点之间的句子自动属于同一个单元。

规则：
1. 第一个起点必须是 0；起点必须按从小到大给出
2. **按脚本的大结构分段，不要按小意群拆**：整条片子通常只有 5~8 个单元。
   宁可粗不可细——一个卖点讲三句话，那三句就是一个单元，不要拆成三个
3. 只在讲述目的真正转换的那一句才设起点
4. 只输出 JSON，不要任何解释或 markdown 标记

输出格式：{"starts":[0,3,7,12]}''';

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

  /// 把模型的回复变成单元草稿。
  ///
  /// **优先读切点协议**（`{"starts":[...]}`）：切点列表怎么写都构不成
  /// 「跳句/重复/遗漏」，合法性由构造保证。旧的「列全每组成员」协议要求模型
  /// 把 27 个索引一个不漏地分配好，实测 mini 有一半的概率做不到，而一次
  /// 不合法就把整份分组作废、退成 27 个碎片单元。
  ///
  /// 旧协议仍然读得懂——模型偶尔会按老格式答；那条路上不合法就按它给的
  /// 起点补齐（见 [GroupingRepair]），并如实上报「已修复」。
  static List<UnitDraft> parseGrouping(
      String content, List<AsrSentence> sentences,
      {SemanticSplitDegradationCallback? onDegraded}) {
    final starts = _tryParseStarts(content);
    final groups = starts == null ? _tryParseIndexGroups(content) : null;
    if (starts == null && groups == null) {
      return _degradeToOneUnitPerSentence(
          sentences, SemanticSplitDegradation.unparsableOutput, onDegraded);
    }

    final repair = GroupingRepair.of(
        starts != null ? [for (final s in starts) [s]] : groups!,
        total: sentences.length);
    if (repair.groups.isEmpty) {
      return _degradeToOneUnitPerSentence(
          sentences, SemanticSplitDegradation.invalidPartition, onDegraded);
    }
    // 切点协议下「补齐」是正常工作方式，不是瑕疵；只有旧协议里模型自己
    // 列漏了才算修复过
    if (starts == null && repair.changed) {
      AppLog.warn(
          '语义分组已修复：${SemanticSplitDegradation.repairedPartition.userMessage}');
      onDegraded?.call(SemanticSplitDegradation.repairedPartition);
    }
    return List.unmodifiable([
      for (final g in repair.groups)
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

  /// 读切点协议。没有 `starts` 字段返回 null（交给旧协议去试）。
  static List<int>? _tryParseStarts(String content) {
    try {
      final json = jsonDecode(_unfence(content)) as Map<String, dynamic>;
      final starts = json['starts'];
      if (starts is! List) return null;
      return [for (final e in starts) (e as num).toInt()];
    } catch (_) {
      return null;
    }
  }

  static String _unfence(String content) {
    final text = content.trim();
    final m = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$').firstMatch(text);
    return m == null ? text : m.group(1)!;
  }

  static List<List<int>>? _tryParseIndexGroups(String content) {
    try {
      final json = jsonDecode(_unfence(content)) as Map<String, dynamic>;
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
}
