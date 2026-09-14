import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/composed_timeline.dart';
import 'package:ishkafel/core/export/export_plan.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

/// 底片固定并切过镜头的那一段，导出要一格格地拼**那条素材**。
/// 没换素材的那几镜从素材上剪——跑去原片同一个时间点剪，
/// 出来的是一段毫不相干的画面，而哪儿都不报错。
void main() {
  List<SemanticUnit> units() => [
        const SemanticUnit(
          uid: 'u0',
          index: 0,
          startMs: 0,
          endMs: 4000,
          transcript: '第一句',
          shots: [Shot(startMs: 0, endMs: 4000)],
        ),
        const SemanticUnit(
          uid: 'u1',
          index: 1,
          startMs: 4000,
          endMs: 10000,
          transcript: '',
          hasSource: false,
          baseCandidateId: 7,
          shots: [
            Shot(startMs: 4000, endMs: 6500),
            Shot(startMs: 6500, endMs: 10000),
          ],
        ),
      ];

  List<ExportCombination> plan({Map<int, List<int>> shotPicks = const {}}) =>
      ExportPlanner.enumerate(
        units: units(),
        replacements: [
          UnitReplacement.keepOriginal(),
          shotPicks.isEmpty
              ? UnitReplacement.whole([7], previewId: 7)
              : UnitReplacement.perShot(shotPicks),
        ],
        materialDurations: const {7: 6000, 9: 3000},
      );

  test('这一段拆成两段导，不是整条塞进去', () {
    final segs = plan().single.segments.where((s) => s.unitIndex == 1).toList();

    expect(segs.length, 2);
  });

  test('没换素材的那几镜从底片上剪——记着是哪条素材、第几毫秒', () {
    final segs = plan().single.segments.where((s) => s.unitIndex == 1).toList();

    expect(segs[0].baseCandidateId, 7);
    expect(segs[0].baseStartMs, 0);
    expect(segs[1].baseCandidateId, 7);
    expect(segs[1].baseStartMs, 2500, reason: '6500 - 单元起点 4000');
  });

  test('取自原片的那一段不带底片标记，照旧从原片剪', () {
    final seg = plan().single.segments.firstWhere((s) => s.unitIndex == 0);

    expect(seg.baseCandidateId, isNull);
    expect(seg.baseStartMs, seg.startMs);
  });

  test('换掉其中一镜：那一镜用新素材，另一镜还是底片', () {
    final segs = plan(shotPicks: {
      1: [9]
    }).single.segments.where((s) => s.unitIndex == 1).toList();

    expect(segs[0].candidateId, isNull, reason: '第一镜没换');
    expect(segs[0].baseCandidateId, 7, reason: '没换的从底片剪');
    expect(segs[1].candidateId, 9, reason: '第二镜换成了 9');
  });

  test('底片换了就是另一段画面：切片缓存不能命中上一张', () {
    const a = ExportSegment(
        startMs: 4000,
        endMs: 6500,
        unitIndex: 1,
        baseCandidateId: 7,
        baseStartMs: 0);
    const b = ExportSegment(
        startMs: 4000,
        endMs: 6500,
        unitIndex: 1,
        baseCandidateId: 8,
        baseStartMs: 0);

    expect(a == b, isFalse);
    expect(a.hashCode == b.hashCode, isFalse);
  });

  group('时间线不再把它画成一整块', () {
    ComposedTimeline axis() => ComposedTimeline.of(
          units: units(),
          wholeDurations: const {1: 6000},
        );

    test('切过自己底片的：有自己的镜头，要一格格画', () {
      expect(axis().hasOwnShots(1), isTrue);
      expect(axis().isSolidBlock(1), isFalse);
    });

    test('镜头在成片上的位置照常算得出来', () {
      expect(axis().composedShotStart(1, 0), 4000);
      expect(axis().composedShotStart(1, 1), 6500);
      expect(axis().composedShotEnd(1, 1), 10000);
    });

    test('字幕规则不变：底片是素材就不渲台词字幕', () {
      expect(axis().isReplaced(1), isTrue,
          reason: '时长跟素材走、和原坑位对不齐，按原时间戳贴字幕必然错位');
    });
  });
}
