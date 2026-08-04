import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart';
import 'package:ishkafel/core/models/tag_group_ref.dart';
import 'package:ishkafel/features/tasks/new_task_wizard/wizard_providers.dart';
import 'package:ishkafel/features/workbench/task_tag_groups_dialog.dart';

class _FakeTagService implements MiaoaTagService {
  @override
  Future<List<TagGroup>> listGroups() async =>
      const [
        TagGroup(
            id: 7,
            name: '植源场景',
            materialType: 'video',
            tagType: 'normal',
            tags: ['台面', '柜门'])
      ];

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 打开「标签组设置」对话框，返回用户保存下来的结果
Future<TaskTagGroups?> _open(
  WidgetTester tester, {
  List<TagGroupRef> unit = const [],
  List<TagGroupRef> shot = const [],
  String unitPrompt = '',
  String shotPrompt = '',
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
                result = await showTaskTagGroupsDialog(
                  context,
                  unit: unit,
                  shot: shot,
                  unitPrompt: unitPrompt,
                  shotPrompt: shotPrompt,
                );
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

const _scene = TagGroupRef(id: 7, name: '植源场景');
const _action = TagGroupRef(id: 8, name: '植源动作');

void main() {
  group('每一层一条打标约束', () {
    testWidgets('已有的约束显示在输入框里', (tester) async {
      await _open(tester, shot: const [_scene], shotPrompt: '只看主体所处的空间');

      expect(find.text('只看主体所处的空间'), findsOneWidget);
    });

    testWidgets('这一层选了四个组，约束框仍然只有一个', (tester) async {
      await _open(tester, shot: const [
        _scene,
        _action,
        TagGroupRef(id: 9, name: '植源外壳'),
        TagGroupRef(id: 10, name: '植源镜头类别'),
      ]);

      expect(find.byKey(const Key('tag-prompt-shot')), findsOneWidget,
          reason: '四个组是同一次打标的四个维度，用户约束的是这一层怎么判；'
              '一组一个框等于逼他把同一句话抄四遍');
    });

    testWidgets('两层各写各的，互不串台', (tester) async {
      TaskTagGroups? captured;
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
                        unit: const [TagGroupRef(id: 1, name: '植源分子库')],
                        shot: const [_scene, _action]);
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
          find.byKey(const Key('tag-prompt-unit')), '按卖点来判，不要判语气');
      await tester.enterText(
          find.byKey(const Key('tag-prompt-shot')), '只判断空间，不要判断动作');
      await tester.pump();
      await tester.tap(find.byKey(const Key('task-tag-groups-save')));
      await tester.pumpAndSettle();

      expect(captured!.unitPrompt, '按卖点来判，不要判语气');
      expect(captured!.shotPrompt, '只判断空间，不要判断动作');
    });

    testWidgets('这一层没选组时不显示约束框', (tester) async {
      await _open(tester, shot: const []);

      expect(find.byKey(const Key('tag-prompt-shot')), findsNothing,
          reason: '这层压根不打标，摆个无归属的输入框只会让用户猜它管什么');
    });

    testWidgets('输入框有说明，用户知道这段话会怎么被用', (tester) async {
      await _open(tester, shot: const [_scene]);

      expect(find.textContaining('打标'), findsWidgets);
    });
  });
}
