import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

void main() {
  group('单元因子（组合数的乘数）', () {
    test('保留原片为 1', () {
      expect(UnitReplacement.keepOriginal().factor, 1);
    });

    test('整体替换 = 候选数（一个候选一条变体）', () {
      expect(UnitReplacement.whole([1, 2, 3]).factor, 3);
    });

    test('整体替换但一个候选都没选，等同保留原片', () {
      expect(UnitReplacement.whole(const []).factor, 1,
          reason: '按 0 计算会让全片组合数直接归零，界面上显示「可导出 0 条」，'
              '而用户只是还没挑而已');
    });

    test('同一候选选两次不让组合数翻倍', () {
      expect(UnitReplacement.whole([7, 7, 8]).factor, 2);
    });

    test('镜头级 = 各镜头候选数的乘积，未替换的镜头按 1 计', () {
      // S1 选 2 个、S2 保留原画面、S3 选 3 个 → 因子 6
      final plan = UnitReplacement.perShot({
        0: [1, 2],
        2: [3, 4, 5],
      });
      expect(plan.factor, 6);
    });

    test('镜头级但一个镜头都没选，因子为 1', () {
      expect(UnitReplacement.perShot(const {}).factor, 1);
      expect(UnitReplacement.perShot({0: const []}).factor, 1,
          reason: '空候选列表等于「这个镜头没选」，不该把整个单元的因子清零');
    });

    test('两级互斥体现在类型上：一个单元只有一个模式', () {
      final whole = UnitReplacement.whole([1, 2]);
      expect(whole.mode, ReplacementMode.whole);
      expect(whole.shotCandidateIds, isEmpty,
          reason: '进入整体替换后镜头级选择必须清空，否则组合数会把两边都乘进去');

      final perShot = UnitReplacement.perShot({
        0: [1]
      });
      expect(perShot.mode, ReplacementMode.perShot);
      expect(perShot.wholeCandidateIds, isEmpty);
    });

    test('候选列表对外只读', () {
      final plan = UnitReplacement.whole([1, 2]);
      expect(() => plan.wholeCandidateIds.add(3), throwsUnsupportedError);
      final perShot = UnitReplacement.perShot({
        0: [1]
      });
      expect(() => perShot.shotCandidateIds[0]!.add(2), throwsUnsupportedError);
    });
  });

  group('全片组合数（笛卡尔积，上限 100）', () {
    test('各单元因子相乘', () {
      final plan = ReplacementPlan([
        UnitReplacement.whole([1, 2]), // 2
        UnitReplacement.keepOriginal(), // 1
        UnitReplacement.perShot({
          0: [1, 2],
          1: [3, 4, 5],
        }), // 6
      ]);
      expect(plan.combinationCount, 12);
      expect(plan.exceedsLimit, isFalse);
    });

    test('空方案组合数为 1（结果与原片相同）', () {
      expect(ReplacementPlan(const []).combinationCount, 1);
      expect(ReplacementPlan([UnitReplacement.keepOriginal()]).isEmpty, isTrue);
    });

    test('恰好 100 条不算超限，101 条算', () {
      final exactly = ReplacementPlan([
        UnitReplacement.whole(List.generate(10, (i) => i)),
        UnitReplacement.whole(List.generate(10, (i) => 100 + i)),
      ]);
      expect(exactly.combinationCount, 100);
      expect(exactly.exceedsLimit, isFalse);

      final over = ReplacementPlan([
        UnitReplacement.whole(List.generate(10, (i) => i)),
        UnitReplacement.whole(List.generate(11, (i) => 100 + i)),
      ]);
      expect(over.exceedsLimit, isTrue);
    });

    test('极端规模不溢出成负数或绕回小值', () {
      // 60 个单元各选 2 个候选 = 2^60，普通 int 乘法会溢出
      final huge = ReplacementPlan(
          List.generate(60, (_) => UnitReplacement.whole([1, 2])));

      expect(huge.exceedsLimit, isTrue,
          reason: '溢出后界面会显示一个荒谬的组合数，甚至让「是否超限」的判断反转，'
              '把上限形同虚设');
      expect(huge.combinationCount, greaterThan(ReplacementPlan.maxCombinations));
    });

    test('超限时要能说出「超了多少」，而不是只说「超了」', () {
      final over = ReplacementPlan([
        UnitReplacement.whole(List.generate(10, (i) => i)),
        UnitReplacement.whole(List.generate(11, (i) => 100 + i)),
        UnitReplacement.whole([1, 2]),
      ]);
      expect(over.preciseCombinationCount, 220);
      expect(over.overflowsPreciseCount, isFalse);
    });

    test('精确组合数同样带饱和，规模荒谬时如实标记而不是给个绕回的假数', () {
      final huge = ReplacementPlan(
          List.generate(60, (_) => UnitReplacement.whole([1, 2])));
      expect(huge.overflowsPreciseCount, isTrue);
      expect(huge.preciseCombinationCount,
          greaterThan(ReplacementPlan.maxCombinations));
    });

    test('因子最大的单元下标（提示用户该从哪里减）', () {
      final plan = ReplacementPlan([
        UnitReplacement.whole([1, 2]),
        UnitReplacement.whole(List.generate(5, (i) => i)),
        UnitReplacement.keepOriginal(),
      ]);
      expect(plan.largestFactorUnitIndex, 1);
      expect(ReplacementPlan(const []).largestFactorUnitIndex, isNull);
      expect(ReplacementPlan([UnitReplacement.keepOriginal()]).largestFactorUnitIndex,
          isNull,
          reason: '全是保留原片时没有「可减的地方」，不能指着一个因子为 1 的单元让用户减');
    });

    test('单元列表对外只读', () {
      final plan = ReplacementPlan([UnitReplacement.keepOriginal()]);
      expect(() => plan.units.clear(), throwsUnsupportedError);
    });
  });
}
