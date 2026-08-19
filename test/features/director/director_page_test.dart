import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/storage/task_repository.dart';
import 'package:ishkafel/features/director/director_page.dart';
import 'package:ishkafel/features/tasks/task_list_controller.dart';

/// 编导台 M1 骨架：左栏脚本编辑 + 自动落盘。
/// 验收口径（实现分期）：建任务 → 写十行脚本 → 关掉重开不丢 → 行操作全可用。
class _MemoryRepo implements TaskRepository {
  final _store = <String, RenewTask>{};
  @override
  Future<List<RenewTask>> findAll() async => _store.values.toList();
  @override
  Future<RenewTask?> findById(String id) async => _store[id];
  @override
  Future<void> save(RenewTask task) async => _store[task.id] = task;
  @override
  Future<void> delete(String id) async => _store.remove(id);
}

RenewTask scriptTask({ScriptDoc? doc}) => RenewTask(
      id: 't1',
      name: '测试脚本',
      sourcePath: null,
      script: doc ?? ScriptDoc.empty(),
      status: RenewTaskStatus.ready,
      createdAt: DateTime.utc(2026, 8, 19),
      updatedAt: DateTime.utc(2026, 8, 19),
    );

Widget wrap(TaskRepository repo, RenewTask task) => ProviderScope(
      overrides: [taskRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(home: DirectorPage(task: task)),
    );

void main() {
  testWidgets('三栏骨架：左脚本、中预览占位（说明自己是什么）、右行工作台', (tester) async {
    await tester.pumpWidget(wrap(_MemoryRepo(), scriptTask()));
    await tester.pumpAndSettle();

    expect(find.text('脚本'), findsOneWidget);
    expect(find.textContaining('预览'), findsWidgets,
        reason: '占位不许是一块死区域，要说明这里将来是什么');
    expect(find.textContaining('画面行'), findsWidgets,
        reason: '新脚本自带一个空行 = 画面行，右栏应显示行工作台');
  });

  testWidgets('写字自动变配音行，右栏跟着变', (tester) async {
    await tester.pumpWidget(wrap(_MemoryRepo(), scriptTask()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '世界上只有两种人');
    await tester.pumpAndSettle();

    expect(find.textContaining('配音行'), findsWidgets);
  });

  testWidgets('回车在当前行后插入新行，选中跳到新行', (tester) async {
    final repo = _MemoryRepo();
    await tester.pumpWidget(wrap(repo, scriptTask()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '第一句');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('2 行'), findsOneWidget);
    expect(find.textContaining('第 2 行 ·'), findsOneWidget,
        reason: '回车后光标应落在新行，右栏跟着切换');
  });

  testWidgets('改动自动落盘（防抖后），不存在「保存」按钮', (tester) async {
    final repo = _MemoryRepo();
    final task = scriptTask();
    await tester.pumpWidget(wrap(repo, task));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '要落盘的一句');
    await tester.pump(const Duration(seconds: 1));

    final saved = await repo.findById('t1');
    expect(saved?.script?.lines.first.text, '要落盘的一句');
    expect(find.text('保存'), findsNothing);
  });

  testWidgets('重开不丢：带已有脚本的任务进来，内容原样呈现', (tester) async {
    var doc = ScriptDoc.empty().updateText(0, '上次写的');
    doc = doc.insertAfter(0, text: '还有这句');
    await tester.pumpWidget(wrap(_MemoryRepo(), scriptTask(doc: doc)));
    await tester.pumpAndSettle();

    expect(find.text('上次写的'), findsOneWidget);
    expect(find.text('还有这句'), findsOneWidget);
  });

  testWidgets('删除行；最后一行删除按钮禁用', (tester) async {
    var doc = ScriptDoc.empty().updateText(0, 'A');
    doc = doc.insertAfter(0, text: 'B');
    await tester.pumpWidget(wrap(_MemoryRepo(), scriptTask(doc: doc)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('script-line-remove-1')));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('B'), findsNothing);
    expect(find.text('1 行'), findsOneWidget);
    final btn = tester.widget<IconButton>(
        find.byKey(const ValueKey('script-line-remove-0')));
    expect(btn.onPressed, isNull, reason: '脚本至少留一行可写');
  });

  testWidgets('画面行可手填时长，落到 manualMs', (tester) async {
    final repo = _MemoryRepo();
    await tester.pumpWidget(wrap(repo, scriptTask()));
    await tester.pumpAndSettle();

    final field = find.byWidgetPredicate((w) =>
        w is TextFormField && w.key.toString().contains('manual-ms'));
    expect(field, findsOneWidget, reason: '空行 = 画面行，右栏应给手填时长入口');
    await tester.enterText(field, '3.5');
    await tester.pump(const Duration(seconds: 1));

    final saved = await repo.findById('t1');
    expect(saved?.script?.lines.first.manualMs, 3500);
  });
}
