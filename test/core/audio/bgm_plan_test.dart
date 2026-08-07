import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';

const _track = BgmMaterial(
    id: 1, name: '轻快电子', durationMs: 30000, previewUrl: null, tags: []);
const _short = BgmMaterial(
    id: 2, name: '五秒垫乐', durationMs: 5000, previewUrl: null, tags: []);

BgmPlan _planWith(List<BgmSegment> segments) => BgmPlan(segments);

void main() {
  group('把一段 BGM 铺到一串连续的视觉镜头上', () {
    test('区间可以跨台词语义单元——配乐本来就不跟台词走', () {
      final plan = const BgmPlan([]).assign(
        startUnit: 3,
        endUnit: 9,
        materials: [_track],
        rangeMs: 20000,
      );

      expect(plan.segments.single.startUnit, 3);
      expect(plan.segments.single.endUnit, 9);
    });

    test('倒着选也认（用户从右往左拖）', () {
      final plan = const BgmPlan([]).assign(
        startUnit: 9,
        endUnit: 3,
        materials: [_track],
        rangeMs: 20000,
      );

      expect(plan.segments.single.startUnit, 3);
      expect(plan.segments.single.endUnit, 9);
    });

    test('段按起点排序，便于逐段渲染与导出', () {
      final plan = const BgmPlan([])
          .assign(startUnit: 10, endUnit: 12, materials: [_track], rangeMs: 8000)
          .assign(startUnit: 0, endUnit: 2, materials: [_short], rangeMs: 8000);

      expect(plan.segments.map((s) => s.startUnit), [0, 10]);
    });
  });

  group('新段压住旧段：改就是改，不留看不见的半截', () {
    test('完全覆盖旧段时旧段消失', () {
      final plan = _planWith([
        const BgmSegment(
            startUnit: 2, endUnit: 5, materials: [_short], fit: BgmFit.loop),
      ]).assign(startUnit: 0, endUnit: 9, materials: [_track], rangeMs: 20000);

      expect(plan.segments.length, 1);
      expect(plan.segments.single.previewMaterial.id, 1);
    });

    test('部分重叠时旧段被裁到不重叠的那部分', () {
      final plan = _planWith([
        const BgmSegment(
            startUnit: 0, endUnit: 5, materials: [_short], fit: BgmFit.loop),
      ]).assign(startUnit: 4, endUnit: 9, materials: [_track], rangeMs: 20000);

      expect(plan.segments.length, 2);
      expect(plan.segments[0].startUnit, 0);
      expect(plan.segments[0].endUnit, 3,
          reason: '旧段留下 0-3，被新段占走的 4-5 交出去');
      expect(plan.segments[1].startUnit, 4);
    });

    test('新段落在旧段中间时旧段被劈成两半', () {
      final plan = _planWith([
        const BgmSegment(
            startUnit: 0, endUnit: 9, materials: [_short], fit: BgmFit.loop),
      ]).assign(startUnit: 4, endUnit: 5, materials: [_track], rangeMs: 4000);

      expect(plan.segments.map((s) => '${s.startUnit}-${s.endUnit}'),
          ['0-3', '4-5', '6-9']);
    });
  });

  group('长的裁、短的循环——用户不必自己算', () {
    test('素材比区间长：裁', () {
      final plan = const BgmPlan([]).assign(
          startUnit: 0, endUnit: 3, materials: [_track], rangeMs: 12000);

      expect(plan.segments.single.fit, BgmFit.cut);
    });

    test('素材比区间短：循环', () {
      final plan = const BgmPlan([]).assign(
          startUnit: 0, endUnit: 3, materials: [_short], rangeMs: 12000);

      expect(plan.segments.single.fit, BgmFit.loop);
    });

    test('差得在半秒以内就当刚好，不写「裁」也不写「循环」', () {
      final plan = const BgmPlan([]).assign(
          startUnit: 0, endUnit: 3, materials: [_short], rangeMs: 5200);

      expect(plan.segments.single.fit, BgmFit.exact,
          reason: '差 0.2 秒还写「会循环播放」，是在吓唬用户');
    });
  });

  group('移除与查询', () {
    test('按镜头下标查它归哪一段管', () {
      final plan = _planWith([
        const BgmSegment(
            startUnit: 2, endUnit: 5, materials: [_track], fit: BgmFit.cut),
      ]);

      expect(plan.segmentAt(3)?.previewMaterial.id, 1);
      expect(plan.segmentAt(6), isNull);
    });

    test('移除某一段不动其余段', () {
      final plan = _planWith([
        const BgmSegment(
            startUnit: 0, endUnit: 1, materials: [_track], fit: BgmFit.cut),
        const BgmSegment(
            startUnit: 4, endUnit: 5, materials: [_short], fit: BgmFit.loop),
      ]).removeAt(4);

      expect(plan.segments.single.startUnit, 0);
    });

    test('移除一个没有配乐的镜头是空操作，不崩', () {
      final plan = const BgmPlan([]).removeAt(3);

      expect(plan.segments, isEmpty);
    });
  });

  group('落盘往返', () {
    test('存下来再读回来是同一份方案', () {
      final plan = const BgmPlan([]).assign(
          startUnit: 1, endUnit: 4, materials: [_track], rangeMs: 8000);

      final back = BgmPlan.fromJson(plan.toJson());

      expect(back.segments.single.startUnit, 1);
      expect(back.segments.single.endUnit, 4);
      expect(back.segments.single.previewMaterial.name, '轻快电子');
      expect(back.segments.single.fit, BgmFit.cut);
    });

    test('畸形数据只丢那一段，不让整条任务读不出来', () {
      final back = BgmPlan.fromJson([
        {'startShot': 0, 'endShot': 2, 'material': {'id': 1, 'name': 'a', 'durationMs': 1000}, 'fit': 'cut'},
        {'startShot': 'bad'},
        'not a map',
      ]);

      expect(back.segments.length, 1,
          reason: '任务 JSON 里一段配乐畸形就让整条任务从列表消失，'
              '用户看到的是「我的任务不见了」');
    });
  });
}
