import '../models/semantic_unit.dart';
import '../models/shot.dart';
import '../models/unit_uid.dart';

/// 把打标结果合并回**当前**的单元列表。
///
/// 为什么不能整份替换：切分一好就把人放进工作台，打标（实测占总时长七成）
/// 在后台补（见 [AnalysisPipeline]）。这七成的时间里人就坐在时间线前面拖
/// 边界——拿打标开始那一刻的单元整份写回去，他这段时间干的活会悄无声息地
/// 没掉。
///
/// 配对**按身份（[SemanticUnit.uid]），不是按下标**。打标这七成时间里人可能
/// 加了单元、拖了顺序，下标早就不是发起打标时那一套了——按下标配，标签会
/// 糊到别人身上（2026-09-16 真机：新加的空单元拖到第一位，凭空带上了隔壁
/// 那个的标签）。身份是发出去就不变的，见 `unit_uid.dart`。
///
/// 合并规则只有一条：**边界一模一样才认**。
/// - 单元的起止变了：这份标签是照着旧边界打的，安到新边界上就是错的
///   （用户改过的单元本来就被标成 [SemanticUnit.tagsStale]，走重新打标那条路）
/// - 单元没动、某个镜头动了：只跳过那个镜头，别的照常合并
/// - 当前已经有标签的：不覆盖。用户手改的、或重新打标写的，都比这份旧结果新
///
/// 入参一个都不改。**没有任何标签可合并时原样返回 [current] 本身**——
/// 调用方靠 `identical` 就能判断要不要真的去动界面（每次列表刷新都无脑
/// 回填的话，undo 栈会被灌满，⌘Z 变得没法用）。
List<SemanticUnit> mergeTagsInto(
  List<SemanticUnit> current,
  List<SemanticUnit> tagged,
) {
  final byUid = {
    for (final u in tagged)
      if (isUnitUid(u.uid)) u.uid: u,
  };
  final merged = [
    for (final unit in current) _mergeUnit(unit, byUid[unit.uid]),
  ];
  return _changed(current, merged) ? merged : current;
}

/// 只看标签有没有变——这个模块本来就只动标签
bool _changed(List<SemanticUnit> a, List<SemanticUnit> b) {
  for (var i = 0; i < a.length; i++) {
    if (unitTagsChanged(a[i], b[i])) return true;
  }
  return false;
}

/// 这个单元（含它的镜头）标签有没有变。**导出给调用方复用**——
/// `mergeTagsInto` 自己拿它判定「要不要真的去动界面」，调用方要按 uid
/// 单独列出「这一笔真正打了标的单元」时也得用它，不能另起一份拷贝。
///
/// **只看单元级 `tags` 不够**：`mergeTagsInto` 还会给标签是空的镜头填
/// `tags`（见 [_mergeShots]）——单元本身已经有人手打的标签（不被覆盖）、
/// 但它下面某个镜头的标签是这次打标填上的，这种情况单元**确实变了**，
/// 只比单元级会漏报（2026-09-18 真机复审揪出来的：「存了却不报」，
/// 查到的空看起来正好像「没问题」）。
///
/// **不能用 `identical` 判断有没有变**：[_mergeUnit] 里的 `copyWith`
/// 即使字段值没变也会造一个新对象，`identical` 在这里只会反过来多报。
bool unitTagsChanged(SemanticUnit a, SemanticUnit b) {
  if (!sameTags(a.tags, b.tags)) return true;
  for (var j = 0; j < a.shots.length && j < b.shots.length; j++) {
    if (!sameTags(a.shots[j].tags, b.shots[j].tags)) return true;
  }
  return false;
}

bool sameTags(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

SemanticUnit _mergeUnit(SemanticUnit current, SemanticUnit? tagged) {
  if (tagged == null || !_sameSpan(current, tagged)) return current;
  return current.copyWith(
    tags: current.tags.isEmpty ? tagged.tags : current.tags,
    trace: current.tags.isEmpty ? tagged.trace : current.trace,
    shots: _mergeShots(current.shots, tagged.shots),
  );
}

List<Shot> _mergeShots(List<Shot> current, List<Shot> tagged) => [
      for (var i = 0; i < current.length; i++)
        if (i < tagged.length &&
            current[i].startMs == tagged[i].startMs &&
            current[i].endMs == tagged[i].endMs &&
            current[i].tags.isEmpty)
          current[i].copyWith(
            tags: tagged[i].tags,
            description: current[i].description ?? tagged[i].description,
            trace: current[i].trace ?? tagged[i].trace,
          )
        else
          current[i],
    ];

bool _sameSpan(SemanticUnit a, SemanticUnit b) =>
    a.startMs == b.startMs && a.endMs == b.endMs;
