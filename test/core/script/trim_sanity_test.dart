import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/script/shot_allocation.dart';

/// 取段起点不能跑到素材长度之外。
///
/// 真机 bug：第 6 句第 2 镜的素材只有 3467ms，取段起点却是 19953ms
/// ——素材长度的 5 倍开外。取段条按它算出「窗口左边缘 = 条宽」，
/// 于是 `clamp(8.0, 0.0)` 上下限颠倒直接抛异常，Release 包把整块面板
/// 渲染成一片灰。
///
/// 怎么写进去的：挑素材那一刻**时长还没探测出来**，setTrimStart 夹不了；
/// 等时长回来了，那个数就悬在外面没人管。
void main() {
  group('探测到素材时长时，把悬空的取段夹回来', () {
    test('取段起点超出素材长度 → 夹到能取的最后位置', () {
      var doc = ScriptDoc([
        ScriptLine.create(text: '句').withShots(const [
          LineShot(materialId: 7, name: 'm', trimStartMs: 19953, allocMs: 2424),
        ]),
      ]);
      doc = doc.withMeasuredDuration(7, 3467);
      final shot = doc.lines.first.shots.first;
      expect(shot.durationMs, 3467);
      expect(shot.trimStartMs, lessThan(3467),
          reason: '取段起点不能落在素材之外——那一镜根本取不到画面');
    });

    test('取段起点本来就合理的不动它', () {
      var doc = ScriptDoc([
        ScriptLine.create(text: '句').withShots(const [
          LineShot(materialId: 7, name: 'm', trimStartMs: 500, allocMs: 1000),
        ]),
      ]);
      doc = doc.withMeasuredDuration(7, 5000);
      expect(doc.lines.first.shots.first.trimStartMs, 500);
    });

    test('夹回来之后还要留得下这一镜要用的那段', () {
      var doc = ScriptDoc([
        ScriptLine.create(text: '句').withShots(const [
          LineShot(materialId: 7, name: 'm', trimStartMs: 9999, allocMs: 2000),
        ]),
      ]);
      doc = doc.withMeasuredDuration(7, 3000);
      final shot = doc.lines.first.shots.first;
      expect(shot.trimStartMs + 2000, lessThanOrEqualTo(3000),
          reason: '起点 + 用量不能超过素材总长');
    });
  });

  group('取段条的算法：数据再离谱也不许崩', () {
    test('窗口左边缘顶到条尾时，宽度算得出来且不为负', () {
      // 这就是那一镜：条宽 200px、素材 3467ms、trim 19953ms
      final r = trimBarMetrics(
          width: 200, sourceMs: 3467, trimStartMs: 19953, allocMs: 2424,
          speed: 1.0);
      expect(r.left, 200);
      expect(r.width, greaterThanOrEqualTo(0));
      expect(r.left + r.width, lessThanOrEqualTo(200));
    });

    test('正常数据照常算', () {
      final r = trimBarMetrics(
          width: 200, sourceMs: 4000, trimStartMs: 1000, allocMs: 2000,
          speed: 1.0);
      expect(r.left, 50);
      expect(r.width, 100);
    });

    test('倍速改变「这条素材能出多长」', () {
      final r = trimBarMetrics(
          width: 200, sourceMs: 4000, trimStartMs: 0, allocMs: 1000,
          speed: 2.0);
      expect(r.width, 100, reason: '2 倍速下 4 秒素材出 2 秒，1 秒占一半');
    });

    test('素材时长为 0 也不崩', () {
      final r = trimBarMetrics(
          width: 200, sourceMs: 0, trimStartMs: 0, allocMs: 1000, speed: 1.0);
      expect(r.width, greaterThanOrEqualTo(0));
    });
  });
}
