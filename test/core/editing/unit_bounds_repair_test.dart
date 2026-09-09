import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/unit_bounds_repair.dart';
import 'package:ishkafel/core/editing/unit_reorder.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';

/// 2026-09-09 真机：同事报「合并视觉镜头之后，后面变成缺失的」，
/// 还有「选中一个镜头去替换，预览会跳回 U1·S1」。
///
/// 起因都不是合并、也不是替换：**在那之前删过一个手动加的台词语义单元**。
/// 那条路走的是空白任务那套重铺时间轴，把每个单元的起止改成连续的一条，
/// 而单元里的视觉镜头留在原地——两层坐标就此各说各话。
///
/// 真机数据长这样（U2 的镜头还在原片的 55.4s~75.3s，单元自己却被挪到了
/// 16.0s~35.9s）：
/// ```
/// U2 单元 16033-35868  镜头 55467-75302   ← 对不上
/// ```
SemanticUnit _unit(int index, int start, int end, List<Shot> shots) =>
    SemanticUnit(
        index: index,
        startMs: start,
        endMs: end,
        transcript: 'u$index',
        shots: shots);

void main() {
  group('删掉手动加的单元：有原片的任务只重排下标', () {
    final units = [
      _unit(0, 0, 1000, [Shot(startMs: 0, endMs: 1000)]),
      // 手动加的：没有镜头
      _unit(1, 1000, 11000, const []),
      _unit(2, 1000, 3000, [
        Shot(startMs: 1000, endMs: 2000),
        Shot(startMs: 2000, endMs: 3000),
      ]),
    ];

    test('剩下的单元起止一毫秒都不许动', () {
      final out = removeUnitAt(units, 1);

      expect(out.length, 2);
      expect(out[1].startMs, 1000);
      expect(out[1].endMs, 3000);
      expect(out[1].shots.first.startMs, 1000,
          reason: '单元和它的镜头都是原片坐标，只挪一层就会对不上');
    });

    test('下标要跟位置一致——替换方案是按下标记的', () {
      final out = removeUnitAt(units, 0);

      expect(out.map((u) => u.index), [0, 1]);
    });

    test('越界不动它，也不崩', () {
      expect(identical(removeUnitAt(units, 9), units), isTrue);
      expect(identical(removeUnitAt(units, -1), units), isTrue);
    });
  });

  group('覆盖到哪儿：取最大值，不是取最后一个', () {
    test('调过序之后最后那个未必覆盖到最远', () {
      final units = [
        _unit(0, 5000, 8000, [Shot(startMs: 5000, endMs: 8000)]),
        _unit(1, 0, 5000, [Shot(startMs: 0, endMs: 5000)]),
      ];

      expect(coveredEndMs(units), 8000);
    });

    test('空列表给 0', () => expect(coveredEndMs(const []), 0));
  });

  group('读档自愈：按镜头把挪错的单元起止修回来', () {
    test('整体平移过的修回镜头那一段', () {
      final broken = [
        _unit(0, 16033, 35868, [
          Shot(startMs: 55467, endMs: 56767),
          Shot(startMs: 56767, endMs: 75302),
        ]),
      ];

      final fixed = repairUnitBoundsFromShots(broken);

      expect(fixed.single.startMs, 55467);
      expect(fixed.single.endMs, 75302);
      expect(fixed.single.shots.length, 2, reason: '镜头一个都不许动');
    });

    test('本来就对得上的原样返回同一个对象——别把 undo 栈灌满', () {
      final ok = [
        _unit(0, 0, 1000, [Shot(startMs: 0, endMs: 1000)]),
      ];

      expect(identical(repairUnitBoundsFromShots(ok), ok), isTrue);
    });

    test('长度都不一样：不猜，原样留着', () {
      final odd = [
        _unit(0, 0, 5000, [Shot(startMs: 0, endMs: 1000)]),
      ];

      expect(repairUnitBoundsFromShots(odd).single.endMs, 5000,
          reason: '这不是「整体被平移」那个 bug，乱修会把好数据改坏');
    });

    test('手动加的单元没有镜头，不动它', () {
      final manual = [_unit(0, 1000, 11000, const [])];

      expect(identical(repairUnitBoundsFromShots(manual), manual), isTrue);
    });
  });
}
