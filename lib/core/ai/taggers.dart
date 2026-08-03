import 'dart:convert';
import 'ark_chat_client.dart';

/// 解析打标输出并按受控词表过滤（两个 Tagger 共用）
List<String> parseVocabTags(String content, List<String> vocabulary) {
  var text = content.trim();
  final fence = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$');
  final m = fence.firstMatch(text);
  if (m != null) text = m.group(1)!;
  try {
    final json = jsonDecode(text) as Map<String, dynamic>;
    final tags = (json['tags'] as List<dynamic>).cast<String>();
    return List.unmodifiable(tags.where(vocabulary.contains));
  } catch (_) {
    return const [];
  }
}

String _vocabPrompt(List<String> vocabulary) => '''
候选标签（受控词表，只能从中选择，禁止自造）：${jsonEncode(vocabulary)}
从候选中选出最贴切的 0-3 个标签。只输出 JSON：{"tags":["标签名"]}''';

/// 台词语义单元打标（文本）
class UnitTagger {
  final ArkChatClient chat;
  UnitTagger({required this.chat});

  Future<List<String>> tag({
    required String transcript,
    required List<String> vocabulary,
  }) async =>
      (await understand(transcript: transcript, vocabulary: vocabulary)).tags;

  /// 带出模型原始回复，供过程量留痕
  Future<ShotUnderstanding> understand({
    required String transcript,
    required List<String> vocabulary,
  }) async {
    if (vocabulary.isEmpty) return const ShotUnderstanding();
    final content = await chat.chatText(
      system: '你是短视频广告素材打标员。${_vocabPrompt(vocabulary)}',
      user: '台词：$transcript',
      maxTokens: 256,
    );
    return ShotUnderstanding(
        tags: parseVocabTags(content, vocabulary), rawReply: content);
  }
}

/// 一个视觉镜头的理解结果
class ShotUnderstanding {
  final List<String> tags;

  /// 模型**原样**返回的内容。解析出错时全靠它定位问题，因此原封不动带出来。
  final String? rawReply;

  /// 这个镜头拍的是什么（一句话）。拿不到时为 null——描述要拿去做语义
  /// 检索，编一句不如没有。
  final String? description;

  const ShotUnderstanding(
      {this.tags = const [], this.description, this.rawReply});
}

/// 视觉镜头理解（多帧走 vision 通道）
class ShotTagger {
  final ArkChatClient chat;
  ShotTagger({required this.chat});

  /// 一次调用同时拿标签和画面描述。
  ///
  /// **多帧而不是一帧**：单帧只能看到一个静止姿态，判不出镜头里在发生什么。
  /// 实测同一镜头 3 帧给出「主播转动身体依次指向不同方向的货位」，单帧只有
  /// 「主播在仓库中直播带货」——描述动作的标签组靠单帧根本打不准。
  ///
  /// **两件事合并成一次调用**：标签和描述看的是同一批帧，分两次调用等于把
  /// 视觉推理做两遍，而它正是整条管线最贵最慢的一步。
  Future<ShotUnderstanding> understand({
    required List<List<int>> frames,
    required List<String> vocabulary,
  }) async {
    if (frames.isEmpty) return const ShotUnderstanding();
    final content = await chat.chatVisionFrames(
      prompt: _shotPrompt(frames.length, vocabulary),
      frames: frames,
      maxTokens: 512,
    );
    return ShotUnderstanding(
      tags: parseVocabTags(content, vocabulary),
      description: _parseDescription(content),
      rawReply: content,
    );
  }

  /// 兼容旧签名（单帧、只要标签）
  Future<List<String>> tag({
    required List<int> frameJpeg,
    required List<String> vocabulary,
  }) async {
    if (vocabulary.isEmpty) return const [];
    final r = await understand(frames: [frameJpeg], vocabulary: vocabulary);
    return r.tags;
  }
}

/// 提示词必须说明「这几张是同一镜头的连续采样」——不说的话模型会把它们
/// 当成几张无关的图分别描述
String _shotPrompt(int frameCount, List<String> vocabulary) {
  final head = frameCount > 1
      ? '这 $frameCount 张图是同一个短视频镜头按时间先后连续采样的画面。'
      : '这是同一个短视频镜头的一张画面。';
  final tagPart = vocabulary.isEmpty
      ? '标签留空数组。'
      : '候选标签（受控词表，只能从中选择，禁止自造）：'
          '${jsonEncode(vocabulary)}\n从候选中选出最贴切的标签，宁缺毋滥。';
  return '$head\n$tagPart\n'
      '同时用一句话描述这个镜头在拍什么（主体、场景、动作），'
      '这句话会被拿去检索画面相近的素材，所以要具体、不要复述台词。\n'
      '只输出 JSON：{"tags":["标签名"],"description":"一句话"}';
}

String? _parseDescription(String content) {
  final json = _tryJson(content);
  final d = json?['description'];
  if (d is! String) return null;
  final trimmed = d.trim();
  return trimmed.isEmpty ? null : trimmed;
}

Map<String, dynamic>? _tryJson(String content) {
  var text = content.trim();
  final m = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$').firstMatch(text);
  if (m != null) text = m.group(1)!;
  try {
    final decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}
