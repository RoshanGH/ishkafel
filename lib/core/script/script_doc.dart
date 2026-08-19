/// 脚本成片（编导台）的数据根：脚本行。
///
/// 「脚本即成片」——**行是唯一概念**（设计稿 2026-08-19）：
/// - **配音行**：有台词。配音生成后其时长是该行时间轴的根
/// - **画面行**：空文案但结构上存在——有画面、可铺 BGM；时长手填或随素材
///
/// 行类型不是用户选的，由文案有无**派生**：空行填上字自动变配音行，
/// 清空文案自动变画面行——编导只管写，不用理解「类型」这个概念。
library;

enum ScriptLineType { voiced, visual }

class ScriptLine {
  /// 稳定身份：重排、镜头组引用、配音产物归属都靠它——行的内容会变，
  /// 身份不变
  final String id;

  final String text;

  /// 画面行的手填时长（毫秒）。null = 未填（随所选素材）。
  /// 配音行忽略此字段——配音时长才是根
  final int? manualMs;

  /// 行标签（M3 打标后挂上，可改可删；检索时自动预填）
  final List<String> tags;

  ScriptLine({
    required this.id,
    required this.text,
    this.manualMs,
    List<String> tags = const [],
  }) : tags = List.unmodifiable(tags);

  static int _seq = 0;

  /// 新行。id 用时间戳+序号，进程内唯一且落盘后稳定
  factory ScriptLine.create({String text = ''}) => ScriptLine(
        id: 'l${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}'
            '${(_seq++).toRadixString(36)}',
        text: text,
      );

  /// 有字就是配音行，没字就是画面行——由内容派生，不由用户选择
  ScriptLineType get type =>
      text.trim().isEmpty ? ScriptLineType.visual : ScriptLineType.voiced;

  ScriptLine withText(String next) =>
      ScriptLine(id: id, text: next, manualMs: manualMs, tags: tags);

  ScriptLine withManualMs(int? ms) =>
      ScriptLine(id: id, text: text, manualMs: ms, tags: tags);

  ScriptLine withTags(List<String> next) =>
      ScriptLine(id: id, text: text, manualMs: manualMs, tags: next);

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        if (manualMs != null) 'manualMs': manualMs,
        if (tags.isNotEmpty) 'tags': tags,
      };

  /// 宽松解析：一条坏行只丢它自己，不牵连整份脚本
  static ScriptLine? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final text = raw['text'];
    if (id is! String || id.isEmpty || text is! String) return null;
    return ScriptLine(
      id: id,
      text: text,
      manualMs: raw['manualMs'] is int ? raw['manualMs'] as int : null,
      tags: [
        if (raw['tags'] is List)
          for (final t in raw['tags'] as List)
            if (t is String) t,
      ],
    );
  }
}

/// 一份脚本。全部操作不可变——返回新文档，绝不原地改。
class ScriptDoc {
  final List<ScriptLine> lines;

  ScriptDoc(List<ScriptLine> lines) : lines = List.unmodifiable(lines);

  /// 新脚本自带一个空行：编导打开就能写，不用先学会「加行」
  factory ScriptDoc.empty() => ScriptDoc([ScriptLine.create()]);

  ScriptDoc insertAfter(int index, {String text = ''}) {
    final next = [...lines];
    next.insert(index + 1, ScriptLine.create(text: text));
    return ScriptDoc(next);
  }

  /// 最后一行不许删——脚本至少有一行可写
  ScriptDoc removeAt(int index) {
    if (lines.length <= 1 || index < 0 || index >= lines.length) return this;
    return ScriptDoc([...lines]..removeAt(index));
  }

  ScriptDoc move(int from, int to) {
    if (from < 0 || from >= lines.length || to < 0 || to >= lines.length) {
      return this;
    }
    final next = [...lines];
    final line = next.removeAt(from);
    next.insert(to, line);
    return ScriptDoc(next);
  }

  ScriptDoc updateText(int index, String text) => _update(
      index, (line) => line.withText(text));

  ScriptDoc setManualMs(int index, int? ms) =>
      _update(index, (line) => line.withManualMs(ms));

  ScriptDoc setTags(int index, List<String> tags) =>
      _update(index, (line) => line.withTags(tags));

  ScriptDoc _update(int index, ScriptLine Function(ScriptLine) f) {
    if (index < 0 || index >= lines.length) return this;
    final next = [...lines];
    next[index] = f(next[index]);
    return ScriptDoc(next);
  }

  Map<String, dynamic> toJson() =>
      {'lines': [for (final l in lines) l.toJson()]};

  /// 宽松解析；整体坏掉退回空脚本（打不开任务比丢一份草稿更糟）
  static ScriptDoc fromJson(Object? raw) {
    if (raw is! Map) return ScriptDoc.empty();
    final rawLines = raw['lines'];
    if (rawLines is! List) return ScriptDoc.empty();
    final lines = [
      for (final l in rawLines) ?ScriptLine.tryFromJson(l),
    ];
    return lines.isEmpty ? ScriptDoc.empty() : ScriptDoc(lines);
  }
}
