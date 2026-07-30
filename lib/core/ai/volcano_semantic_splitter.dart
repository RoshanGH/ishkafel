import 'dart:convert';
import '../analysis/providers.dart';
import '../analysis/segmentation_builder.dart';
import '../log/app_log.dart';
import 'ark_chat_client.dart';

/// LLM 语义分组（句子索引协议）：模型只分组，不产时间戳——边界由代码从句子时间戳推导
class VolcanoSemanticSplitter implements SemanticSplitter {
  final ArkChatClient chat;

  VolcanoSemanticSplitter({required this.chat});

  static const _systemPrompt = '''
你是短视频广告的台词语义切分专家。台词语义单元的定义：一段表达完整语义的台词（可能一句或多句），
如"痛点引入""产品介绍""功效演示""价格机制""行动号召"等各为一个单元。

规则：
1. 只能按给出的句子顺序分组，不得跳句、不得重排、不得遗漏任何句子索引
2. 相邻的同语义句子合为一个单元；语义转折处切开
3. 只输出 JSON，不要任何解释或 markdown 标记

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
    );
    return parseGrouping(content, sentences);
  }

  /// 解析并校验分组；任何不合法整体回退「每句一单元」
  static List<UnitDraft> parseGrouping(
      String content, List<AsrSentence> sentences) {
    final groups = _tryParseIndexGroups(content);
    if (groups == null || !_isValidPartition(groups, sentences.length)) {
      AppLog.warn('语义分组输出不合法，回退每句一单元');
      return List.unmodifiable([
        for (final s in sentences)
          UnitDraft(startMs: s.startMs, endMs: s.endMs, transcript: s.text),
      ]);
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
