import 'dart:convert';

import 'package:meta/meta.dart';

import 'ark_chat_client.dart';
import 'tag_dimension.dart';

/// 打标用的模型。
///
/// **换成 mini 是拿标签密度换速度，这是产品决定**。同一批真实镜头实测：
/// lite 每个镜头 13~25 秒、平均打 8.2 个标签；mini 4.7~9.6 秒、平均 4.8 个。
/// 标签是「按相同标签检索候选素材」的唯一检索键，打得少意味着能匹配上的
/// 素材也少——所以这是有代价的，将来觉得候选太少可以换回 lite（改这一个常量）。
///
/// 画面描述两者都能写，mini 更啰嗦些（每条都以「这个镜头拍摄的是…」开头）。
const String taggingModel = 'doubao-seed-2-0-mini-260428';

/// 台词语义单元打标（文本）
class UnitTagger {
  final ArkChatClient chat;
  UnitTagger({required this.chat});

  /// 按维度打标，并带出模型原始回复供过程量留痕。
  ///
  /// 一个标签组 = 一个维度，各带各的词表（见 [TagDimension]）；用户写的
  /// [constraint] 是整层一条，对所有维度都生效。
  Future<ShotUnderstanding> understand({
    required String transcript,
    required List<TagDimension> dimensions,
    String? constraint,
  }) async {
    if (dimensions.isEmpty) return const ShotUnderstanding();
    final content = await chat.chatText(
      system: '你是短视频广告素材打标员。\n'
          '${buildDimensionPrompt(dimensions, constraint: constraint)}',
      user: '台词：$transcript',
      maxTokens: 512,
      // 打标是判断题：同一段素材重跑一次不该给出另一套标签
      temperature: 0,
      model: taggingModel,
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

  /// 画面里露出的产品是谁家的。**本片是什么品牌，只能从原片自己的产品
  /// 露出镜头看出来**——候选素材之间品牌打架能自己比出来，但「候选和本片
  /// 对不对得上」要有一个参照。null = 没有产品露出，或认不出牌子。
  final String? productBrand;

  /// 画面里烧着的文字（字幕、贴片文案、品牌角标）。
  ///
  /// **这条素材能不能用，往往就看它**：拿去换画面时我们还要再烧一行台词
  /// 字幕，两套字幕叠在一起、而且内容毫不相干——片子直接废。
  /// 而它在画面描述里一个字都看不出来（真机：描述写「成人给小孩按摩额头」，
  /// 画面底部烧着别家品牌的「冰冰凉凉的好舒服呀」）。
  final List<String> burnedText;

  const ShotUnderstanding({
    this.tags = const [],
    this.tagsByDimension = const {},
    this.description,
    this.burnedText = const [],
    this.productBrand,
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
    String? constraint,
  }) async {
    // 没帧就没什么可看的；但**没有维度仍然要问**——画面描述不依赖词表，
    // 而它正是「按画面描述检索素材」的检索键。没选标签组就连描述也不给，
    // 等于把这条路一起堵死。
    if (frames.isEmpty) return const ShotUnderstanding();
    final content = await chat.chatVisionFrames(
      prompt: buildShotUnderstandingPrompt(frames.length, dimensions, constraint),
      frames: frames,
      maxTokens: 768,
      temperature: 0,
      model: taggingModel,
    );
    final parsed = parseDimensionTags(content, dimensions);
    return ShotUnderstanding(
      tags: parsed.flatTags,
      tagsByDimension: parsed.byDimension,
      description: _parseDescription(content),
      burnedText: _parseBurnedText(content),
      productBrand: _parseProductBrand(content),
      rawReply: content,
    );
  }
}

/// 提示词必须说明「这几张是同一镜头的连续采样」——不说的话模型会把它们
/// 当成几张无关的图分别描述
@visibleForTesting
String buildShotUnderstandingPrompt(
    int frameCount, List<TagDimension> dimensions, String? constraint) {
  final head = frameCount > 1
      ? '这 $frameCount 张图是同一个短视频镜头按时间先后连续采样的画面'
          '（依次为镜头的开头、中间、结尾）。'
      : '这是同一个短视频镜头的一张画面。';
  return '$head\n${buildDimensionPrompt(dimensions, constraint: constraint)}\n'
      '另外用一句话描述这个镜头在拍什么（主体、场景、动作），放在 '
      '"description" 键下。这句话会被拿去检索画面相近的素材，'
      '所以要具体、不要复述台词。\n'
      // **画面里烧着的字是致命信息**：拿这条素材去换画面时，我们还要往上
      // 烧一行台词字幕，两套字幕会打架，而且那句话跟本片台词毫无关系
      // ——片子直接废。而它在画面描述里一个字都看不出来（真机撞到：
      // 描述写「成人给小孩按摩额头」，画面底部烧着「冰冰凉凉的好舒服呀」）
      '最后：画面里如果**烧着文字**（字幕、贴片文案、品牌角标），'
      '把看到的文字原样放在 "burnedText" 键下（数组，没有就给空数组）。'
      '这一条很要紧——这条素材被拿去换画面时还要再烧一行字，'
      '两套字幕叠在一起片子就废了。\n'
      // **本片是什么品牌，只能从原片自己的产品露出镜头看出来**。
      // 候选素材之间品牌打架能自己比出来，但「候选和本片对不对得上」
      // 要有个参照，那个参照只能来自这里。而且这一句是白问的：
      // 视觉打标本来就在看图、本来就是一次调用
      '还有：画面里如果有**产品露出**（有人拿着、摆着、或在用某个商品），'
      '把那个产品的品牌写进 "productBrand"（读包装和 logo）；'
      '画面里没有产品、或者认不出是什么牌子，一律给 null'
      '——瞎猜一个牌子比承认不知道更糟。';
}

/// 画面里露出的产品是谁家的。**本片是什么品牌，只能从这里看出来**——
/// 候选素材之间品牌打架能自己比出来，但「候选和本片对不对得上」要有一个
/// 参照。null = 画面里没有产品露出，或认不出牌子（瞎猜一个牌子更糟）。
String? _parseProductBrand(String content) {
  final raw = _tryJson(content)?['productBrand'];
  if (raw is! String) return null;
  final t = raw.trim();
  return t.isEmpty || _notABrand.contains(t.toLowerCase()) ? null : t;
}

/// 「看不出来」的各种说法。模型有时不肯给 null，改说「无」「未知」
const Set<String> _notABrand = {
  '无', '没有', '未知', '不确定', '看不清', '不清楚', '空',
  'none', 'null', 'n/a', 'na', 'unknown', 'unclear', 'no', 'nil',
};

/// 画面里烧着的文字。**只有看图才发现得了**，而它决定这条素材能不能用
List<String> _parseBurnedText(String content) {
  final raw = _tryJson(content)?['burnedText'];
  if (raw is! List) return const [];
  return [
    for (final e in raw)
      if (e is String && e.trim().isNotEmpty) e.trim(),
  ];
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
