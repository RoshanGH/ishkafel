import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/miaoa/miaoa_project_service.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart';
import 'package:ishkafel/core/models/project_ref.dart';
import 'package:ishkafel/core/models/tag_group_ref.dart';
import 'package:ishkafel/features/tasks/new_task_wizard/wizard_providers.dart';
import 'package:ishkafel/features/workbench/task_tag_groups_dialog.dart';

class _FakeTagService implements MiaoaTagService {
  @override
  Future<List<TagGroup>> listGroups() async => const [
        TagGroup(
            id: 7,
            name: '植源场景',
            materialType: 'video',
            tagType: 'normal',
            tags: ['台面'])
      ];

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeProjectService implements MiaoaProjectService {
  var calls = 0;

  @override
  Future<List<MiaoaProject>> listProjects() async {
    calls++;
    return const [
      MiaoaProject(id: 104, name: '滴露植源喷雾'),
      MiaoaProject(id: 139, name: '滴露达播'),
    ];
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 对话框是异步返回的：`_open` 返回时它还开着，所以结果得放在一个盒子里
class _Harness {
  TaskTagGroups? saved;
  final projects = _FakeProjectService();
}

Future<_Harness> _open(
  WidgetTester tester, {
  ProjectRef? project,
}) async {
  final harness = _Harness();
  final projects = harness.projects;
  await tester.pumpWidget(ProviderScope(
    overrides: [
      miaoaTagServiceProvider.overrideWithValue(_FakeTagService()),
      miaoaProjectServiceProvider.overrideWithValue(projects),
    ],
    child: MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const Key('open'),
              onPressed: () async {
                harness.saved = await showTaskTagGroupsDialog(
                  context,
                  unit: const [],
                  shot: const [TagGroupRef(id: 7, name: '植源场景')],
                  project: project,
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
  return harness;
}

void main() {
  group('标签组设置里定「上哪儿找素材」', () {
    testWidgets('选一个项目，保存后带出来', (tester) async {
      final harness = await _open(tester);

      await tester.tap(find.byKey(const Key('project-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('project-104')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('task-tag-groups-save')));
      await tester.pumpAndSettle();

      expect(harness.saved!.project,
          const ProjectRef(id: 104, name: '滴露植源喷雾'));
    });

    testWidgets('选回「不限项目」保存后是 null，而不是留着上一个', (tester) async {
      final harness = await _open(tester,
          project: const ProjectRef(id: 104, name: '滴露植源喷雾'));

      await tester.tap(find.byKey(const Key('project-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('project-any')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('task-tag-groups-save')));
      await tester.pumpAndSettle();

      expect(harness.saved!.project, isNull,
          reason: '改回不限项目却还按老项目搜，用户会以为这个开关是坏的');
    });

    testWidgets('已选的项目显示在字段上', (tester) async {
      await _open(tester, project: const ProjectRef(id: 104, name: '滴露植源喷雾'));

      expect(find.text('滴露植源喷雾'), findsOneWidget);
    });

    testWidgets('没选项目时写明是全部项目，不留白让人猜', (tester) async {
      await _open(tester);

      expect(find.textContaining('不限项目'), findsOneWidget);
    });

    testWidgets('不点开就不拉项目列表——多数任务沿用上一条的项目', (tester) async {
      final projects = (await _open(tester)).projects;

      expect(projects.calls, 0);

      await tester.tap(find.byKey(const Key('project-field')));
      await tester.pumpAndSettle();

      expect(projects.calls, 1);
    });

    testWidgets('能改回「不限项目」', (tester) async {
      await _open(tester, project: const ProjectRef(id: 104, name: '滴露植源喷雾'));

      await tester.tap(find.byKey(const Key('project-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('project-any')));
      await tester.pumpAndSettle();

      expect(find.textContaining('不限项目'), findsOneWidget);
    });

    testWidgets('项目多的时候能搜', (tester) async {
      await _open(tester);

      await tester.tap(find.byKey(const Key('project-field')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('project-search')), '达播');
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('project-139')), findsOneWidget);
      expect(find.byKey(const Key('project-104')), findsNothing);
    });
  });
}
