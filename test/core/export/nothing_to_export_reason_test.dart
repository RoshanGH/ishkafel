import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/export_plan.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

/// **一条都排不出来时，必须说得出为什么。**
///
/// 2026-09-09 设计走查真机：U1·S7 和 U3·S1 都挑了素材 116719，而一条成片里
/// 不允许同一条素材出现两次——于是每一种排法都被丢掉，对话框显示「共 0 条
/// 成片」、导出按钮灰着，一个字的解释都没有。人不知道自己做错了什么，
/// 也不知道回去改哪儿。
List<SemanticUnit> _units() => [
      const SemanticUnit(
        uid: 'u1',
        index: 0,
        startMs: 0,
        endMs: 4000,
        transcript: 'U1',
        shots: [Shot(startMs: 0, endMs: 2000), Shot(startMs: 2000, endMs: 4000)],
      ),
      const SemanticUnit(
        uid: 'u2',
        index: 1,
        startMs: 4000,
        endMs: 8000,
        transcript: 'U2',
        shots: [Shot(startMs: 4000, endMs: 8000)],
      ),
    ];

void main() {
  _blockedAtTheDoor();
  test('两个位置挑了同一条素材：点名是哪条、在哪几处', () {
    final clashes = ExportPlanner.materialsUsedTwice([
      UnitReplacement.perShot({
        1: [116719],
      }),
      UnitReplacement.perShot({
        0: [116719],
      }),
    ]);

    expect(clashes[116719], ['U1·S2', 'U2·S1'],
        reason: '要说得出「回去改哪儿」，光说「排不出来」等于没说');
  });

  test('确实一条都排不出来——诊断说的和实际发生的是同一件事', () {
    final replacements = [
      UnitReplacement.perShot({
        1: [116719],
      }),
      UnitReplacement.perShot({
        0: [116719],
      }),
    ];

    expect(
        ExportPlanner.enumerate(units: _units(), replacements: replacements),
        isEmpty);
    expect(
        ExportPlanner.materialsUsedTwice(replacements), isNotEmpty);
  });

  test('各挑各的素材时没有元凶可点', () {
    final clashes = ExportPlanner.materialsUsedTwice([
      UnitReplacement.perShot({
        1: [116719],
      }),
      UnitReplacement.perShot({
        0: [200],
      }),
    ]);

    expect(clashes, isEmpty);
  });

  test('整体替换的位置也算进去——它同样会撞', () {
    final clashes = ExportPlanner.materialsUsedTwice([
      UnitReplacement.whole([500]),
      UnitReplacement.perShot({
        0: [500],
      }),
    ]);

    expect(clashes[500], ['U1', 'U2·S1']);
  });

  test('同一个位置挑了好几条不算撞——那本来就是候选列表', () {
    final clashes = ExportPlanner.materialsUsedTwice([
      UnitReplacement.perShot({
        0: [1, 2, 3],
      }),
      UnitReplacement.keepOriginal(),
    ]);

    expect(clashes, isEmpty);
  });
}

/// **一条都排不出来时，在入口就拦住。**
///
/// 2026-09-10 真机走查：底部状态栏说「当前组合 2 条」、导出对话框说
/// 「共 0 条成片」、而「进入矩阵导出」按钮照样可以点——三个地方各说各的。
/// 根子是「排不出来」这件事只有对话框知道。
void _blockedAtTheDoor() {
  group('躲不开的撞车', () {
    test('两个位置都只有同一条素材：必撞，入口就该拦', () {
      final clashes = ExportPlanner.unavoidableClashes([
        UnitReplacement.perShot({
          1: [116719],
        }),
        UnitReplacement.perShot({
          0: [116719],
        }),
      ]);

      expect(clashes[116719], ['U1·S2', 'U2·S1']);
    });

    test('其中一处还有别的候选：躲得开，不许拦', () {
      final clashes = ExportPlanner.unavoidableClashes([
        UnitReplacement.perShot({
          1: [116719],
        }),
        UnitReplacement.perShot({
          0: [116719, 200],
        }),
      ]);

      expect(clashes, isEmpty,
          reason: '第二处换成 200 就不撞了，拦下来是冤枉');
    });

    test('各挑各的，没有撞车', () {
      final clashes = ExportPlanner.unavoidableClashes([
        UnitReplacement.perShot({
          0: [1],
        }),
        UnitReplacement.perShot({
          0: [2],
        }),
      ]);

      expect(clashes, isEmpty);
    });

    test('整体替换的位置也算', () {
      final clashes = ExportPlanner.unavoidableClashes([
        UnitReplacement.whole([500]),
        UnitReplacement.whole([500]),
      ]);

      expect(clashes[500], ['U1', 'U2']);
    });

    test('判断跟实际枚举的结果一致——说拦就是真的排不出来', () {
      final replacements = [
        UnitReplacement.perShot({
          1: [116719],
        }),
        UnitReplacement.perShot({
          0: [116719],
        }),
      ];

      expect(ExportPlanner.unavoidableClashes(replacements), isNotEmpty);
      expect(
          ExportPlanner.enumerate(units: _units(), replacements: replacements),
          isEmpty);
    });
  });
}
