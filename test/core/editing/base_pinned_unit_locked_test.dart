import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/edit_locks.dart';
import 'package:ishkafel/core/editing/segmentation_edit_ops.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

/// 固定过底片的单元，**单元这一层的编辑一律不做**。
///
/// 它的镜头是按那张底片切出来的，坐标是「startMs + 底片内偏移」。一动单元
/// 边界，偏移关系就全错——画面会去取素材里另一个时间点，而哪儿都不报错。
/// 界面上这些单元本来就被 EditLocks 锁着，这里拦的是命令行和别的调用方。
void main() {
  /// U0 取自原片 0~10000；U1 取自原片 10000~14000，但底片换成了 6 秒的
  /// 素材 7 并按它切成三镜——**末镜头到 16000，超出 unit.endMs**
  List<SemanticUnit> units() => [
        const SemanticUnit(
            uid: 'u0',
            index: 0,
            startMs: 0,
            endMs: 10000,
            transcript: '第一句',
            shots: [Shot(startMs: 0, endMs: 10000)]),
        const SemanticUnit(
          uid: 'u1',
          index: 1,
          startMs: 10000,
          endMs: 14000,
          transcript: '第二句',
          baseCandidateId: 7,
          shots: [
            Shot(startMs: 10000, endMs: 12000),
            Shot(startMs: 12000, endMs: 14480),
            Shot(startMs: 14480, endMs: 16000),
          ],
        ),
      ];

  test('拖单元边界：拒绝，不是悄悄改', () {
    expect(SegmentationEditOps.moveUnitBoundary(units(), 0, 9000, fps: 25),
        isNull);
  });

  test('拆分：拒绝——拆完两半各自的镜头还挂着同一张底片的偏移', () {
    expect(
      SegmentationEditOps.splitUnitAt(units(), 1, 12500,
          fps: 25, sentences: const []),
      isNull,
      reason: '过去这里会直接抛断言，等于崩给用户看',
    );
  });

  test('合并：拒绝——两串镜头量的是两张不同的底片', () {
    expect(SegmentationEditOps.mergeUnitWithPrevious(units(), 1), isNull);
  });

  test('没固定底片的单元照旧能拖能拆能合', () {
    final plain = [
      const SemanticUnit(
          uid: 'a',
          index: 0,
          startMs: 0,
          endMs: 10000,
          transcript: '第一句',
          shots: [Shot(startMs: 0, endMs: 10000)]),
      const SemanticUnit(
          uid: 'b',
          index: 1,
          startMs: 10000,
          endMs: 14000,
          transcript: '第二句',
          shots: [Shot(startMs: 10000, endMs: 14000)]),
    ];

    expect(SegmentationEditOps.moveUnitBoundary(plain, 0, 9000, fps: 25),
        isNotNull);
    expect(SegmentationEditOps.mergeUnitWithPrevious(plain, 1), isNotNull);
  });

  group('不变量校验要认得底片这回事', () {
    test('镜头盖的是底片、不是坑位——这份数据是合法的', () {
      expect(
        SegmentationEditOps.holdsInvariants(units(), 14000, 25),
        isTrue,
        reason: '照原样要求「末镜头 endMs == 单元 endMs」会把合法数据判成坏的',
      );
    });

    test('镜头起点仍然要贴着单元起点：这一条不能松', () {
      final bad = [
        units()[0],
        units()[1].copyWith(shots: const [
          Shot(startMs: 10040, endMs: 12000),
          Shot(startMs: 12000, endMs: 16000),
        ]),
      ];

      expect(SegmentationEditOps.holdsInvariants(bad, 14000, 25), isFalse);
    });

    test('镜头之间仍然不许有缝', () {
      final bad = [
        units()[0],
        units()[1].copyWith(shots: const [
          Shot(startMs: 10000, endMs: 12000),
          Shot(startMs: 12400, endMs: 16000),
        ]),
      ];

      expect(SegmentationEditOps.holdsInvariants(bad, 14000, 25), isFalse);
    });

    test('底片的末镜头照常要落在帧上——它是底片的末尾，跟片长无关', () {
      final bad = [
        units()[0],
        units()[1].copyWith(shots: const [
          Shot(startMs: 10000, endMs: 12000),
          Shot(startMs: 12000, endMs: 16013),
        ]),
      ];

      expect(SegmentationEditOps.holdsInvariants(bad, 14000, 25), isFalse);
    });
  });

  group('镜头这一层是活的——那正是这个功能要给的能力', () {
    final plans = [
      UnitReplacement.keepOriginal(),
      UnitReplacement.whole([7], previewId: 7),
    ];

    test('整体替换但没切过底片：整个单元钉死，镜头也动不了', () {
      final plain = [
        units()[0],
        units()[1].copyWith(shots: const [Shot(startMs: 10000, endMs: 14000)]),
      ];
      // 抹掉底片标记 = 普通的整体替换
      final noBase = [
        plain[0],
        SemanticUnit.fromJson(
            Map<String, dynamic>.from(plain[1].toJson())..remove('baseCandidateId')),
      ];
      final locks = EditLocks.of(plans, semanticUnits: noBase);

      expect(locks.isUnitLocked(1), isTrue);
      expect(locks.isShotBoundaryLocked(1), isTrue,
          reason: '那些镜头在成片里已经不存在了，调它们没有意义');
    });

    test('固定过底片：单元层还锁着，镜头层放行', () {
      final locks = EditLocks.of(plans, semanticUnits: units());

      expect(locks.isUnitLocked(1), isTrue, reason: '单元边界一动镜头就全对不上');
      expect(locks.isShotBoundaryLocked(1), isFalse,
          reason: '这些镜头是这条素材上的刀口，调它们正是要给的能力');
      expect(locks.basePinned, contains(1));
    });

    test('单独挑过素材的那一镜仍然锁着', () {
      final locks = EditLocks.of([
        UnitReplacement.keepOriginal(),
        UnitReplacement.perShot({
          1: [9]
        }),
      ], semanticUnits: units());

      expect(locks.isShotLocked(1, 1), isTrue);
    });
  });
}
