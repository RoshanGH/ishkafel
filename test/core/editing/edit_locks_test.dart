import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/edit_locks.dart';
import 'package:ishkafel/core/editing/segmentation_editor_controller.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

/// 挑过替换素材的单元/镜头，切分钉死。
///
/// 这不是保守，是**修一个真实的逻辑洞**：替换方案按下标记（第几个单元、
/// 第几个镜头）。切一刀、并一次，下标全变，原本钉在 S6 上的素材就跑到别的
/// 镜头上去了。改边界更隐蔽——镜头从 2.9 秒改成 4 秒，那条 5.5 秒的素材
/// 得按新倍率重新变速，已渲染的切片全作废，而用户毫不知情。
void main() {
  List<SemanticUnit> unitsOf() => [
        SemanticUnit(
          index: 0,
          startMs: 0,
          endMs: 6000,
          transcript: 'A',
          shots: const [
            Shot(startMs: 0, endMs: 2000),
            Shot(startMs: 2000, endMs: 4000),
            Shot(startMs: 4000, endMs: 6000),
          ],
        ),
        SemanticUnit(
          index: 1,
          startMs: 6000,
          endMs: 12000,
          transcript: 'B',
          shots: const [
            Shot(startMs: 6000, endMs: 8000),
            Shot(startMs: 8000, endMs: 10000),
            Shot(startMs: 10000, endMs: 12000),
          ],
        ),
        SemanticUnit(
          index: 2,
          startMs: 12000,
          endMs: 18000,
          transcript: 'C',
          shots: const [
            Shot(startMs: 12000, endMs: 15000),
            Shot(startMs: 15000, endMs: 18000),
          ],
        ),
      ];

  SegmentationEditorController controllerWith(EditLocks locks) =>
      SegmentationEditorController(
        initialUnits: unitsOf(),
        durationMs: 18000,
        fps: 30,
        sentences: const [],
      )..locks = locks;

  group('从替换方案认出该钉哪些', () {
    test('挑过整体替换的单元，连同它里面每个镜头一起钉死', () {
      final locks = EditLocks.of([
        UnitReplacement.whole(const [101]),
        UnitReplacement.keepOriginal(),
      ]);
      expect(locks.isUnitLocked(0), isTrue);
      expect(locks.isShotLocked(0, 2), isTrue, reason: '整段都换掉了，里面的镜头在成片里已经不存在');
      expect(locks.isUnitLocked(1), isFalse);
    });

    test('只钉挑过素材的那个镜头，同一单元里的别的镜头照常可编辑', () {
      final locks = EditLocks.of([
        UnitReplacement.keepOriginal(),
        UnitReplacement.perShot(const {
          1: [201]
        }),
      ]);
      expect(locks.isShotLocked(1, 1), isTrue);
      expect(locks.isShotLocked(1, 0), isFalse);
      expect(locks.isUnitLocked(1), isFalse);
      expect(locks.unitHasAnyLock(1), isTrue, reason: '整个单元的结构不能动了');
    });

    test('看的是有没有候选，不是有没有设预览', () {
      // 挑了两个候选、一个都没标 ★ 也照钉——用户原话「不管是否有预览的内容」
      final locks = EditLocks.of([
        UnitReplacement.perShot(const {
          0: [301, 302]
        }),
      ]);
      expect(locks.isShotLocked(0, 0), isTrue);
    });

    test('空候选不算挑过', () {
      final locks = EditLocks.of([
        UnitReplacement.whole(const []),
        UnitReplacement.perShot(const {0: []}),
      ]);
      expect(locks.isEmpty, isTrue);
    });
  });

  group('钉住之后改不动边界', () {
    test('镜头挑过素材，它两侧的边界都拖不动', () {
      final c = controllerWith(EditLocks(shots: {ShotRef(1, 1)}));
      expect(c.moveShotBoundary(1, 0, 7000), isFalse, reason: 'S2 的起点');
      expect(c.takeBlockedReason(), contains('S2'));
      expect(c.moveShotBoundary(1, 1, 9000), isFalse, reason: 'S2 的终点');
      expect(c.takeBlockedReason(), isNotNull);
      // 没被钉的那一刀照常
      expect(c.moveShotBoundary(0, 0, 2500), isTrue);
      expect(c.takeBlockedReason(), isNull);
    });

    test('单元被整体替换，里面哪一刀都动不了', () {
      final c = controllerWith(EditLocks(units: {1}));
      expect(c.moveShotBoundary(1, 0, 7000), isFalse);
      expect(c.takeBlockedReason(), contains('U2'));
    });

    test('单元边界会改到两侧的首尾镜头，那两个被钉就不许动', () {
      // U1 的最后一个镜头被钉：U1|U2 这条边界动不了
      final c = controllerWith(EditLocks(shots: {ShotRef(0, 2)}));
      expect(c.moveUnitBoundary(0, 6500), isFalse);
      expect(c.takeBlockedReason(), isNotNull);
      // 但 U2|U3 这条与它无关，照常
      expect(c.moveUnitBoundary(1, 12500), isTrue);
    });

    test('±帧步进走的是同一道闸，不能绕过去', () {
      final c = controllerWith(EditLocks(shots: {ShotRef(1, 1)}));
      c.select(EditorSelection.shot(1, 1));
      expect(c.nudgeSelectedEdge(startEdge: true, frames: 1), isFalse);
      expect(c.takeBlockedReason(), isNotNull);
      expect(c.nudgeSelectedEdge(startEdge: false, frames: -1), isFalse);
      expect(c.takeBlockedReason(), isNotNull);
    });
  });

  group('钉住之后切不开、并不掉', () {
    test('钉住的镜头切不开', () {
      final c = controllerWith(EditLocks(shots: {ShotRef(1, 1)}));
      c.select(EditorSelection.shot(1, 1));
      expect(c.splitSelectedAt(9000), isFalse);
      expect(c.takeBlockedReason(), contains('S2'));
    });

    test('单元里只要有一个镜头钉住，整个单元就切不开——切开下标全乱', () {
      final c = controllerWith(EditLocks(shots: {ShotRef(1, 2)}));
      c.select(EditorSelection.unit(1));
      expect(c.splitSelectedAt(9000), isFalse);
      expect(c.takeBlockedReason(), contains('S3'));
    });

    test('钉住的镜头既不能被吞，也不能去吞前一个', () {
      final c = controllerWith(EditLocks(shots: {ShotRef(1, 1)}));
      c.select(EditorSelection.shot(1, 1));
      expect(c.mergeSelectedWithPrevious(), isFalse, reason: 'S2 自己要消失');
      expect(c.takeBlockedReason(), isNotNull);
      c.select(EditorSelection.shot(1, 2));
      expect(c.mergeSelectedWithPrevious(), isFalse, reason: 'S3 吞掉 S2');
      expect(c.takeBlockedReason(), isNotNull);
    });

    test('合并单元时两边都要查——并完两边的镜头下标都变了', () {
      final c = controllerWith(EditLocks(shots: {ShotRef(0, 1)}));
      c.select(EditorSelection.unit(1));
      expect(c.mergeSelectedWithPrevious(), isFalse, reason: 'U1 里有钉住的镜头');
      expect(c.takeBlockedReason(), contains('U1'));
    });

    test('没钉的地方一切照旧', () {
      final c = controllerWith(EditLocks(shots: {ShotRef(2, 0)}));
      c.select(EditorSelection.unit(1));
      expect(c.splitSelectedAt(9000), isTrue);
      expect(c.takeBlockedReason(), isNull);
    });
  });

  group('拦下来要说人话', () {
    test('点名是哪个、为什么、怎么解开', () {
      final c = controllerWith(EditLocks(shots: {ShotRef(1, 1)}));
      c.select(EditorSelection.shot(1, 1));
      c.splitSelectedAt(9000);
      final reason = c.takeBlockedReason()!;
      expect(reason, contains('U2'));
      expect(reason, contains('S2'));
      expect(reason, contains('替换素材'));
      expect(reason, contains('移除'), reason: '要告诉用户怎么解开，不能只说不行');
    });

    test('原因读一次就清掉，不会粘在界面上', () {
      final c = controllerWith(EditLocks(units: {0}));
      c.select(EditorSelection.unit(0));
      c.splitSelectedAt(3000);
      expect(c.takeBlockedReason(), isNotNull);
      expect(c.takeBlockedReason(), isNull);
    });

    test('单元里多个镜头被钉时一次点全，不用挨个试', () {
      final c = controllerWith(
          EditLocks(shots: {ShotRef(1, 0), ShotRef(1, 2)}));
      c.select(EditorSelection.unit(1));
      c.mergeSelectedWithPrevious();
      final reason = c.takeBlockedReason()!;
      expect(reason, contains('S1'));
      expect(reason, contains('S3'));
    });
  });
}
