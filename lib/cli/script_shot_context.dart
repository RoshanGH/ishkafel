import '../core/script/script_doc.dart';
import '../core/script/shot_allocation.dart';

/// 给第 [lineIndex] 行挑镜头时，Agent 需要知道的**全部事实**。
///
/// spec 第一节划的线：软件提供事实与保护，方法论归 skill。所以这里只把
/// 「挑得好不好」所依赖的事实一次给全，不排序、不推荐、不打分：
///
/// - `reference`：参考片这一镜长什么样——**要复刻的就是它**
/// - `neighbors`：前后镜头是什么画面，避免「每个都对、连起来不对」
/// - `usedElsewhere`：整片已用的素材，避免几句话撞同一条（同一批素材
///   常有微调版，撞了会让片子看着像卡带）
/// - `slotMs`：这一行要铺多长，决定素材够不够
Map<String, dynamic> scriptShotContext(
  ScriptDoc doc,
  int lineIndex, {
  /// 参考片这一镜的**本地首帧**（Agent 拿它去「看」画面）。
  /// 返回 null 表示这一镜没抽到帧——不给假路径
  String? Function(int shotIndex)? refFrameOf,
}) {
  if (lineIndex < 0 || lineIndex >= doc.lines.length) {
    throw ArgumentError('第 ${lineIndex + 1} 行不存在（脚本共 ${doc.lines.length} 行）');
  }
  final line = doc.lines[lineIndex];
  final ref = line.reference;
  final refSegments = ref?.segments ?? const <(int, int)>[];
  final refShots = [
    for (var k = 0; k < refSegments.length; k++)
      () {
        final (start, end) = refSegments[k];
        final meta = ref!.metaAt(start);
        return {
          'index': k,
          'startMs': start,
          'endMs': end,
          'description': meta?.description ?? '',
          'tags': meta?.tags ?? const <String>[],
          'asr': ref.segmentText(k, ''),
          // 本地首帧：**让 Agent 真的看见这一镜长什么样**，
          // 而不是只读一句画面描述。描述是别人（打标 AI）总结的，
          // 看图才是第一手
          'framePath': ?refFrameOf?.call(k),
        };
      }(),
  ];
  final untagged = refShots.isNotEmpty &&
      refShots.every((s) => '${s['description']}'.trim().isEmpty);

  return {
    'lineIndex': lineIndex,
    'text': line.text,
    if (line.tags.isNotEmpty) 'tags': line.tags,
    'slotMs': ShotAllocation.rootMsOf(line) ?? 0,
    'picked': [
      for (final s in line.shots)
        {
          'materialId': s.materialId,
          'name': s.name,
          if (s.allocMs != null) 'allocMs': s.allocMs,
        },
    ],
    'reference': refShots,
    'neighbors': {
      'prev': _neighbor(doc, lineIndex - 1),
      'next': _neighbor(doc, lineIndex + 1),
    },
    'usedElsewhere': [
      for (final l in doc.lines)
        for (final s in l.shots)
          if (s.localSource == null) s.materialId,
    ],
    // 提示要给**能照做的命令**，不是描述状态。
    // 真机上「先打标」这句指向的命令当时根本不存在，Agent 只能自己
    // ffmpeg 抽帧、肉眼看图、手写关键词——中间多一层有损转译，
    // 写偏一点就搜回一堆别的品牌
    if (ref == null)
      'hint': '这一行没有参考片。自己给一句**画面描述**去搜：'
          'ishkafel script shots <任务> --line ${lineIndex + 1} '
          '--by content --keyword "一只手在厨房台面上举着喷雾瓶"。'
          '描述的是画面，不是台词'
    else if (untagged)
      'hint': '参考镜还没打标——没有画面描述、没有标签、也没有首帧图，'
          '这三样正是挑镜头的依据。先打标：'
          'ishkafel script tag-ref <任务> --line ${lineIndex + 1}。'
          '打完再回来 shots，候选会照着参考镜的画面搜，'
          '而且标签会把检索收窄在本任务的词表里',
  };
}

Map<String, dynamic>? _neighbor(ScriptDoc doc, int index) {
  if (index < 0 || index >= doc.lines.length) return null;
  final line = doc.lines[index];
  return {
    'lineIndex': index,
    'text': line.text,
    'shots': [
      for (final s in line.shots)
        {
          'materialId': s.materialId,
          'name': s.name,
          if (s.sceneDescription.isNotEmpty)
            'sceneDescription': s.sceneDescription,
        },
    ],
  };
}
