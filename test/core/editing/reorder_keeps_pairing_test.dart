import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/unit_reorder.dart';
import 'package:ishkafel/core/export/export_plan.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

/// 拖完顺序之后，**每个单元身上还是原来那条素材**。
///
/// 这是这次改动里最容易漏、也最致命的一条：列表挪了、替换方案没挪，
/// 不会报任何错，只会让成片悄悄变成另一个样子——人要把片子导出来看一遍
/// 才可能发现 U1 放的是当初挑给 U2 的素材。
SemanticUnit _u(int index) => SemanticUnit(
      index: index,
      startMs: index * 1000,
      endMs: (index + 1) * 1000,
      transcript: 'U${index + 1}',
    );

void main() {
  test('拖完顺序，素材还跟着原来那个单元', () {
    final units = [_u(0), _u(1), _u(2)];
    final plans = [
      UnitReplacement.whole(const [101]), // 给 U1 挑的
      UnitReplacement.whole(const [202]), // 给 U2 挑的
      UnitReplacement.whole(const [303]), // 给 U3 挑的
    ];

    // 把 U3 拖到最前面
    final movedUnits = moveUnit(units, from: 2, to: 0);
    final movedPlans = remapReplacementsAfterMove(plans, from: 2, to: 0, unitCount: 3);

    // 逐个核对「这个单元」和「它的素材」还是当初那一对
    final pairs = [
      for (var i = 0; i < movedUnits.length; i++)
        (movedUnits[i].transcript, movedPlans[i].wholeCandidateIds.single),
    ];
    expect(pairs, [('U3', 303), ('U1', 101), ('U2', 202)]);
  });

  test('导出计划按新顺序出段落，每段的素材也是对的', () {
    final units = moveUnit([_u(0), _u(1), _u(2)], from: 2, to: 0);
    final plans = remapReplacementsAfterMove([
      UnitReplacement.whole(const [101]),
      UnitReplacement.whole(const [202]),
      UnitReplacement.whole(const [303]),
    ], from: 2, to: 0, unitCount: 3);

    final combos = ExportPlanner.enumerate(units: units, replacements: plans);

    expect(combos.single.segments.map((s) => s.candidateId), [303, 101, 202],
        reason: '成片里第一段就该是当初挑给 U3 的那条素材');
  });
}
