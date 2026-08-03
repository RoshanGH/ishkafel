import 'dart:convert';

import 'ark_chat_client.dart';
import 'tag_dimension.dart';

/// 台词语义单元打标（文本）
class UnitTagger {
  final ArkChatClient chat;
  UnitTagger({required this.chat});

  /// 按维度打标，并带出模型原始回复供过程量留痕。
  ///
  /// 一个标签组 = 一个维度，各带各的词表与各自的约束（见 [TagDimension]）。
  Future<ShotUnderstanding> understand({
    required String transcript,
    required List<TagDimension> dimensions,
  }) async {
    if (dimensions.isEmpty) return const ShotUnderstanding();
    final content = await chat.chatText(
      system: '你是短视频广告素材打标员。\n${buildDimensionPrompt(dimensions)}',
      user: '台词：$transcript',
      maxTokens: 512,
    );
    final parsed = parseDimensionTags(content, dimensions);
    return ShotUnderstanding(
      tags: parsed.flatTags,
      tagsByDimension: parsed.byDimension,
      rawReply: content,
    );
  }
}

/// 一个视觉镜头的理解结果
class ShotUnderstanding {
  /// 按维度顺序拼平、去重的标签。落在 `Shot.tags` 上供检索与展示。
  final List<String> tags;

  /// 维度名 → 该维度选中的标签。展示时按维度分开显示，用户才看得出
  /// 「场景判成了什么、动作判成了什么」，而不是一堆混在一起的词。
  final Map<String, List<String>> tagsByDimension;

  /// 模型**原样**返回的内容。解析出错时全靠它定位问题，因此原封不动带出来。
  final String? rawReply;

  /// 这个镜头拍的是什么（一句话）。拿不到时为 null——描述要拿去做语义
  /// 检索，编一句不如没有。
  final String? description;

  const ShotUnderstanding({
    this.tags = const [],
    this.tagsByDimension = const {},
    this.description,
    this.rawReply,
  });
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
    required List<TagDimension> dimensions,
  }) async {
    // 没帧就没什么可看的；但**没有维度仍然要问**——画面描述不依赖词表，
    // 而它正是「按画面描述检索素材」的检索键。没选标签组就连描述也不给，
    // 等于把这条路一起堵死。
    if (frames.isEmpty) return const ShotUnderstanding();
    final content = await chat.chatVisionFrames(
      prompt: _shotPrompt(frames.length, dimensions),
      frames: frames,
      maxTokens: 768,
    );
    final parsed = parseDimensionTags(content, dimensions);
    return ShotUnderstanding(
      tags: parsed.flatTags,
      tagsByDimension: parsed.byDimension,
      description: _parseDescription(content),
      rawReply: content,
    );
  }
}

/// 提示词必须说明「这几张是同一镜头的连续采样」——不说的话模型会把它们
/// 当成几张无关的图分别描述
String _shotPrompt(int frameCount, List<TagDimension> dimensions) {
  final head = frameCount > 1
      ? '这 $frameCount 张图是同一个短视频镜头按时间先后连续采样的画面'
          '（依次为镜头的开头、中间、结尾）。'
      : '这是同一个短视频镜头的一张画面。';
  return '$head\n${buildDimensionPrompt(dimensions)}\n'
      '另外用一句话描述这个镜头在拍什么（主体、场景、动作），放在 '
      '"description" 键下。这句话会被拿去检索画面相近的素材，'
      '所以要具体、不要复述台词。';
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
