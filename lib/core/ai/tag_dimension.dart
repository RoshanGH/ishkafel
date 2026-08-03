import 'dart:convert';

/// 打标的一个**维度**：一个标签组 = 一个维度。
///
/// 为什么要有这个概念：此前多个标签组被合并成一张扁平词表，一次问完。模型
/// 面对几十个混在一起的词，没有「每个维度各答一份」的概念，于是一个镜头
/// 一口气给出「实拍 / 厨房情景 / 常规清洁 / 细菌清洁 / 灶台置物台面 / 橱柜 /
/// 打开电器」——横跨四个维度，每个维度都没有约束。
///
/// 分维度不等于分多次调用：拆成四次会让最贵最慢的视觉推理翻四倍。做法是
/// **一次调用、提示词里分段、输出按维度分格**。
class TagDimension {
  /// 维度名（就是标签组名），同时是输出 JSON 的键
  final String name;

  /// 这个维度的受控词表
  final List<String> vocabulary;

  /// 用户为这个标签组写的打标约束。每个项目的口径不同，写死在代码里的
  /// 通用提示词打不出用户要的那套标签。
  final String? prompt;

  const TagDimension({
    required this.name,
    required this.vocabulary,
    required this.prompt,
  });
}

/// 一次分维度打标的结果
class DimensionTags {
  /// 维度名 → 该维度选中的标签（键一定齐全，模型漏答的维度为空列表）
  final Map<String, List<String>> byDimension;

  /// 按维度顺序拼平、去重后的标签。落在 `Shot.tags`/`SemanticUnit.tags` 上，
  /// 供检索与展示使用。
  final List<String> flatTags;

  const DimensionTags({required this.byDimension, required this.flatTags});
}

/// 拼出分维度的提示词片段。
///
/// 每个维度自成一段：维度名 + 它自己的词表 + 它自己的约束。约束必须紧跟在
/// 它所属的维度后面——落到别的维度下面等于给错了指令。
String buildDimensionPrompt(List<TagDimension> dimensions) {
  final buffer = StringBuffer();
  for (final d in dimensions) {
    buffer.writeln('【${d.name}】');
    buffer.writeln('候选标签（只能从中选，禁止自造）：${jsonEncode(d.vocabulary)}');
    final prompt = d.prompt?.trim();
    // 没写约束就不留一个空的「约束：」——空指令会让模型去猜它省略了什么
    if (prompt != null && prompt.isNotEmpty) {
      buffer.writeln('本维度约束：$prompt');
    }
    buffer.writeln();
  }
  buffer.writeln('逐个维度作答，每个维度只从它自己的候选里选，宁缺毋滥。');
  buffer.write('只输出 JSON，键就是上面的维度名：');
  buffer.writeln(jsonEncode({
    for (final d in dimensions) d.name: ['标签名'],
  }));
  return buffer.toString();
}

/// 按维度解析模型回复。
///
/// 三条纪律：
/// - 每个维度只留**它自己词表**里的词。模型经常把「打开电器」答到「场景」
///   维度下——不挡掉的话，「维度分开」就只是提示词上说说而已；
/// - 维度键一定齐全，模型漏答的给空列表，界面上才显示得出「这个维度没打上」；
/// - 回复不是 JSON 时返回空结果而不是抛异常——一个镜头的回复格式不对，
///   不该把整批打标打断。
DimensionTags parseDimensionTags(String content, List<TagDimension> dimensions) {
  final json = _tryJsonObject(content);
  final byDimension = <String, List<String>>{};
  final flat = <String>[];

  for (final d in dimensions) {
    final raw = json?[d.name];
    final picked = raw is List
        ? raw.whereType<String>().where(d.vocabulary.contains).toList()
        : <String>[];
    byDimension[d.name] = List.unmodifiable(picked);
    for (final t in picked) {
      // 扁平列表是给检索用的，同一个标签重复两遍只会让检索键变脏
      if (!flat.contains(t)) flat.add(t);
    }
  }

  return DimensionTags(
    byDimension: Map.unmodifiable(byDimension),
    flatTags: List.unmodifiable(flat),
  );
}

Map<String, dynamic>? _tryJsonObject(String content) {
  var text = content.trim();
  // 模型常把 JSON 包在 ``` 里
  final fence = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$').firstMatch(text);
  if (fence != null) text = fence.group(1)!;
  try {
    final decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}
