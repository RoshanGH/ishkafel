import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/blank_unit_ops.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/features/blank_task/blank_unit_list.dart';

/// 空白任务的分子列表。
///
/// 盯的是**用户能不能一眼看出片子现在什么样**：哪个填了、哪个没填、总共多长。
void main() {
  List<SemanticUnit> unitsOf(int n) {
    var list = <SemanticUnit>[];
    for (var i = 0; i < n; i++) {
      list = BlankUnitOps.append(list);
    }
    return list;
  }

  Future<void> pump(
    WidgetTester tester, {
    required List<SemanticUnit> units,
    int? Function(int)? durationOf,
    void Function(int)? onDelete,
    VoidCallback? onAdd,
  }) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 600,
            child: BlankUnitList(
              units: units,
              durationOf: durationOf ?? (_) => null,
              selectedIndex: units.isEmpty ? null : 0,
              onSelect: (_) {},
              onAdd: onAdd ?? () {},
              onDelete: onDelete ?? (_) {},
              onReorder: (_, _) {},
            ),
          ),
        ),
      ));

  testWidgets('一个分子都没有时，说清楚下一步做什么', (tester) async {
    await pump(tester, units: const []);
    expect(find.textContaining('还没有分子'), findsWidgets);
    expect(find.textContaining('打上标签'), findsOneWidget);
    expect(find.text('添加'), findsOneWidget, reason: '空态也要能加');
  });

  testWidgets('没挑素材的分子标「待填」，不显示一个编出来的秒数', (tester) async {
    await pump(tester, units: unitsOf(2));
    expect(find.text('待填'), findsNWidgets(2));
    expect(find.textContaining('2.0 秒'), findsNothing,
        reason: '占位长度是内部坐标，绝不能当成时长显示给用户');
  });

  testWidgets('挑了素材的显示真实秒数', (tester) async {
    await pump(tester,
        units: unitsOf(2), durationOf: (i) => i == 0 ? 4500 : null);
    expect(find.text('4.5 秒'), findsOneWidget);
    expect(find.text('待填'), findsOneWidget);
  });

  testWidgets('总时长只算已填的，并把还差几个说出来', (tester) async {
    await pump(tester,
        units: unitsOf(3), durationOf: (i) => i < 2 ? 3000 : null);
    expect(find.textContaining('已填 2 个共 6.0 秒'), findsOneWidget);
    expect(find.textContaining('还有 1 个没填'), findsOneWidget);
  });

  testWidgets('全填满了要能一眼看出来', (tester) async {
    await pump(tester, units: unitsOf(2), durationOf: (_) => 2500);
    expect(find.textContaining('都填满了'), findsOneWidget);
  });

  testWidgets('没有标签的分子用警示色标出来——没标签就搜不出素材', (tester) async {
    await pump(tester, units: unitsOf(1));
    expect(find.text('还没有标签'), findsOneWidget);
  });

  testWidgets('有标签的把标签列出来，不用点进去才知道', (tester) async {
    await pump(tester,
        units: BlankUnitOps.setTags(unitsOf(1), 0, ['厨房情景', '实拍']));
    expect(find.text('厨房情景 · 实拍'), findsOneWidget);
  });

  testWidgets('删除按钮把下标交出去', (tester) async {
    final deleted = <int>[];
    await pump(tester, units: unitsOf(2), onDelete: deleted.add);
    await tester.tap(find.byIcon(Icons.close).last);
    await tester.pump();
    expect(deleted, [1]);
  });
}
