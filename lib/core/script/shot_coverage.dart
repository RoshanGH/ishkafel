import 'script_doc.dart';

/// 一处「画面铺不满坑位」的窟窿
typedef ShotGap = ({
  int lineIndex,
  int shotIndex,
  int materialId,
  String name,
  int allocMs,
  int usableMs,
  int gapMs,
});

/// 取整误差不算窟窿：帧对齐、倍速折算都会差个几十毫秒
const _toleranceMs = 120;

/// 全片有哪些镜头的**素材长度不够铺满它的坑位**。
///
/// 这种窟窿两边都会露馅，而且长得不一样，很难联想到同一个原因（真机
/// 踩到过）：成片里靠克隆最后一帧补满，看到的是画面**定格**几秒；
/// 预览里 EDL 段声明的长度超过文件实际长度，mpv 读到文件尾就收，
/// 于是画面轨整体缩水、配音被反复拽回同一处，听到的是**台词重复**。
///
/// 根子是素材时长「未知」时按无限长处理（见 [LineShot.availableMs]）——
/// 那是为了让还没下载完的素材也能先排上，代价是探测失败的素材会被随便
/// 分配。所以量到真实时长之后必须回头查一遍，这就是这里做的事。
List<ShotGap> shotCoverageGaps(ScriptDoc doc) => [
      for (var i = 0; i < doc.lines.length; i++)
        ...lineShotGaps(doc.lines[i], lineIndex: i),
    ];

/// 一行里铺不满的镜头
List<ShotGap> lineShotGaps(ScriptLine line, {int lineIndex = 0}) {
  final gaps = <ShotGap>[];
  for (var j = 0; j < line.shots.length; j++) {
    final shot = line.shots[j];
    final alloc = shot.allocMs;
    // 时长还不知道（没下载完 / 探测失败还没回填）：不猜
    if (alloc == null || shot.durationMs == null) continue;
    final usable = shot.availableMs;
    if (alloc - usable <= _toleranceMs) continue;
    gaps.add((
      lineIndex: lineIndex,
      shotIndex: j,
      materialId: shot.materialId,
      name: shot.name,
      allocMs: alloc,
      usableMs: usable,
      gapMs: alloc - usable,
    ));
  }
  return gaps;
}
