import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart';
import 'package:ishkafel/core/models/tag_group_ref.dart';
import 'package:ishkafel/features/tasks/new_task_wizard/wizard_providers.dart';
import 'package:ishkafel/features/workbench/task_tag_groups_dialog.dart';

class _FakeTagService implements MiaoaTagService {
  @override
  Future<List<TagGroup>> listGroups() async => const [
        TagGroup(
            id: 7,
            name: '植源场景',
            materialType: 'storyboard',
            tagType: 'public',
            tags: ['厨房情景']),
      ];

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<TaskTagGroups?> _open(
  WidgetTester tester, {
  required List<TagGroupRef> shot,
}) async {
  TaskTagGroups? result;
  await tester.pumpWidget(ProviderScope(
    overrides: [miaoaTagServiceProvider.overrideWithValue(_FakeTagService())],
    child: MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const Key('open'),
              onPressed: () async {
                result = await showTaskTagGroupsDialog(context,
                    unit: const [], shot: shot);
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.byKey(const Key('open')));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  group('每个标签组后面能贴一段打标约束', () {
    testWidgets('已有的约束显示在输入框里', (tester) async {
      await _open(tester, shot: const [
        TagGroupRef(id: 7, name: '植源场景', prompt: '只看主体所处的空间'),
      ]);

      expect(find.text('只看主体所处的空间'), findsOneWidget);
    });

    testWidgets('改了约束，保存后带出来', (tester) async {
      TaskTagGroups? captured;
      await tester.runAsync(() async {});
      await tester.pumpWidget(ProviderScope(
        overrides: [
          miaoaTagServiceProvider.overrideWithValue(_FakeTagService())
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  key: const Key('open'),
                  onPressed: () async {
                    captured = await showTaskTagGroupsDialog(context,
                        unit: const [],
                        shot: const [TagGroupRef(id: 7, name: '植源场景')]);
                  },
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(const Key('tag-prompt-shot-7')), '只判断空间，不要判断动作');
      await tester.pump();
      await tester.tap(find.byKey(const Key('task-tag-groups-save')));
      await tester.pumpAndSettle();

      expect(captured!.shot.single.prompt, '只判断空间，不要判断动作');
    });

    testWidgets('没选组时不显示任何约束输入框', (tester) async {
      await _open(tester, shot: const []);

      expect(find.byKey(const Key('tag-prompt-shot-7')), findsNothing,
          reason: '组都没选，先让用户选组，别把一个没有归属的输入框摆在那儿');
    });

    testWidgets('输入框有说明，用户知道这段话会怎么被用', (tester) async {
      await _open(tester, shot: const [TagGroupRef(id: 7, name: '植源场景')]);

      expect(find.textContaining('打标'), findsWidgets);
    });
  });
}
