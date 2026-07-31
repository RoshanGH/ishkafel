import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/features/picking/picking_controller.dart';

/// 三个单元：U1 两个镜头、U2 三个镜头、U3 没有镜头（场景检测没切出来）
List<SemanticUnit> _units() => const [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 9000,
        transcript: '衣服洗完还是有异味',
        shots: [
          Shot(startMs: 0, endMs: 4000),
          Shot(startMs: 4000, endMs: 9000),
        ],
      ),
      SemanticUnit(
        index: 1,
        startMs: 9000,
        endMs: 26000,
        transcript: '滴露植源喷雾',
        shots: [
          Shot(startMs: 9000, endMs: 14000),
          Shot(startMs: 14000, endMs: 20000),
          Shot(startMs: 20000, endMs: 26000),
        ],
      ),
      SemanticUnit(
          index: 2, startMs: 26000, endMs: 30000, transcript: '点击下方小黄车'),
    ];

void main() {
  group('初始化与向后兼容', () {
    test('没有历史方案时全部按保留原片起步', () {
      final c = PickingController(units: _units());
      expect(c.replacements, hasLength(3));
      expect(c.replacements.every((r) => r.mode == ReplacementMode.keepOriginal),
          isTrue);
      expect(c.dirty, isFalse);
    });

    test('历史方案比单元少时补位、比单元多时截断（切分改过之后仍要能打开）', () {
      final short = PickingController(
          units: _units(), initial: [UnitReplacement.whole([1])]);
      expect(short.replacements, hasLength(3));
      expect(short.replacements[0].wholeCandidateIds, [1]);
      expect(short.replacements[2].mode, ReplacementMode.keepOriginal);

      final long = PickingController(
        units: _units(),
        initial: List.generate(5, (_) => UnitReplacement.whole([9])),
      );
      expect(long.replacements, hasLength(3));
    });

    test('替换方案列表对外只读（不把可变集合暴露出去）', () {
      final c = PickingController(units: _units());
      expect(() => c.replacements.add(UnitReplacement.keepOriginal()),
          throwsUnsupportedError);
    });

    test('空单元列表不崩（脏数据兜底）', () {
      final c = PickingController(units: const []);
      expect(c.replacements, isEmpty);
      expect(c.plan.combinationCount, 1);
    });
  });

  group('替换模式三态互斥', () {
    test('切到整体替换后选候选，镜头级被锁定', () {
      final c = PickingController(units: _units())..setMode(ReplacementMode.whole);
      expect(c.perShotLocked, isFalse, reason: '还没选候选时不该锁，用户要能反悔');
      c.toggleCandidate(11);
      expect(c.perShotLocked, isTrue);
      expect(c.wholeLocked, isFalse);
    });

    test('切到镜头级后选候选，整体替换被锁定', () {
      final c = PickingController(units: _units())
        ..setMode(ReplacementMode.perShot);
      expect(c.selectedShotIndex, 0, reason: '进入镜头级要自动落到第一个视觉镜头上');
      c.toggleCandidate(11);
      expect(c.wholeLocked, isTrue);
      expect(c.perShotLocked, isFalse);
    });

    test('没有视觉镜头的单元不允许进入镜头级（没有可替换的对象）', () {
      final c = PickingController(units: _units())..selectUnit(2);
      expect(c.canUsePerShot, isFalse);
      c.setMode(ReplacementMode.perShot);
      expect(c.currentMode, ReplacementMode.keepOriginal,
          reason: '不能悄悄进入一个没有镜头条可操作的模式');
    });

    test('切换模式会丢弃已选候选时，控制器要能提前告知（供 UI 二次确认）', () {
      final c = PickingController(units: _units())..setMode(ReplacementMode.whole);
      expect(c.discardsSelectionsWhenSwitchingTo(ReplacementMode.keepOriginal),
          isFalse);
      c.toggleCandidate(11);
      expect(c.discardsSelectionsWhenSwitchingTo(ReplacementMode.keepOriginal),
          isTrue);
      expect(c.discardsSelectionsWhenSwitchingTo(ReplacementMode.whole), isFalse);
    });

    test('真的切走时旧选择被清空，组合数不会把两边都乘进去', () {
      final c = PickingController(units: _units())..setMode(ReplacementMode.whole);
      c.toggleCandidate(11);
      c.toggleCandidate(12);
      c.setMode(ReplacementMode.perShot);
      expect(c.currentReplacement.wholeCandidateIds, isEmpty);
      expect(c.currentReplacement.factor, 1);
    });
  });

  group('候选勾选', () {
    test('整体替换：再点一次取消勾选', () {
      final c = PickingController(units: _units())..setMode(ReplacementMode.whole);
      c.toggleCandidate(11);
      expect(c.isCandidateSelected(11), isTrue);
      expect(c.selectedCountInScope, 1);
      c.toggleCandidate(11);
      expect(c.isCandidateSelected(11), isFalse);
      expect(c.currentMode, ReplacementMode.whole,
          reason: '取消最后一个候选不该把模式也一起退回保留原片');
    });

    test('镜头级：勾选只落在当前选中的视觉镜头上', () {
      final c = PickingController(units: _units())
        ..setMode(ReplacementMode.perShot);
      c.toggleCandidate(11);
      c.selectShot(1);
      expect(c.isCandidateSelected(11), isFalse, reason: 'S2 还没选任何候选');
      c.toggleCandidate(21);
      c.toggleCandidate(22);
      expect(c.currentReplacement.shotCandidateIds[0], [11]);
      expect(c.currentReplacement.shotCandidateIds[1], [21, 22]);
      expect(c.currentReplacement.factor, 2);
    });

    test('保留原片模式下勾选不生效（没有可放置的位置）', () {
      final c = PickingController(units: _units());
      c.toggleCandidate(11);
      expect(c.currentReplacement.mode, ReplacementMode.keepOriginal);
      expect(c.dirty, isFalse, reason: '什么都没改就不该被标记为有未保存改动');
    });

    test('每次改动都产生新对象，不就地修改（不可变）', () {
      final c = PickingController(units: _units())..setMode(ReplacementMode.whole);
      final before = c.replacements;
      c.toggleCandidate(11);
      expect(identical(before, c.replacements), isFalse);
      expect(before[0].wholeCandidateIds, isEmpty, reason: '旧快照不得被改写');
    });
  });

  group('单元切换与因子', () {
    test('各单元的方案互不影响，plan 按单元顺序聚合', () {
      final c = PickingController(units: _units());
      c.setMode(ReplacementMode.whole);
      c.toggleCandidate(1);
      c.toggleCandidate(2);
      c.selectUnit(1);
      c.setMode(ReplacementMode.perShot);
      c.toggleCandidate(11);
      c.selectShot(2);
      c.toggleCandidate(21);
      c.toggleCandidate(22);
      c.toggleCandidate(23);

      expect(c.plan.units.map((u) => u.factor).toList(), [2, 3, 1]);
      expect(c.plan.combinationCount, 6);
    });

    test('切回上一个单元时恢复它自己的模式与镜头选中', () {
      final c = PickingController(units: _units())
        ..setMode(ReplacementMode.perShot);
      c.selectShot(1);
      c.selectUnit(1);
      expect(c.currentMode, ReplacementMode.keepOriginal);
      c.selectUnit(0);
      expect(c.currentMode, ReplacementMode.perShot);
      expect(c.selectedShotIndex, 0,
          reason: '回到镜头级单元默认落回第一个镜头，避免停在一个用户已看不见的选中上');
    });

    test('越界的单元/镜头下标被忽略而不是崩溃', () {
      final c = PickingController(units: _units());
      c.selectUnit(99);
      expect(c.selectedUnitIndex, 0);
      c.setMode(ReplacementMode.perShot);
      c.selectShot(99);
      expect(c.selectedShotIndex, 0);
    });
  });

  group('未保存改动标记', () {
    test('改过就是 dirty，保存后清除', () {
      final c = PickingController(units: _units())..setMode(ReplacementMode.whole);
      expect(c.dirty, isTrue);
      c.markSaved();
      expect(c.dirty, isFalse);
    });

    test('只切换选中（不改方案）不算 dirty', () {
      final c = PickingController(units: _units());
      c.selectUnit(1);
      c.selectShot(0);
      expect(c.dirty, isFalse);
    });
  });

  test('通知监听者（UI 靠它重建）', () {
    final c = PickingController(units: _units());
    var notified = 0;
    c.addListener(() => notified++);
    c.selectUnit(1);
    c.setMode(ReplacementMode.whole);
    c.toggleCandidate(1);
    expect(notified, 3);
  });
}
