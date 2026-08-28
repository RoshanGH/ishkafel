import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart';
import 'package:ishkafel/core/models/tag_group_ref.dart';
import 'package:ishkafel/features/tasks/new_task_wizard/new_task_wizard.dart';
import 'package:ishkafel/features/tasks/new_task_wizard/wizard_providers.dart';

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

void main() {
  _promptInWizard();
  _promptSurvivesStart();

  testWidgets('新建任务时预填上一条任务的标签组，连同它的打标约束', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [miaoaTagServiceProvider.overrideWithValue(_FakeTagService())],
      child: const MaterialApp(
        home: Scaffold(
          body: NewTaskWizard(
            prefillShotGroups: [TagGroupRef(id: 7, name: '植源场景')],
            prefillShotPrompt: '只判断空间',
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('植源场景'), findsWidgets,
        reason: '同一个项目里连着建好几条任务是常态，每次重选四个组、'
            '重贴两段约束纯属折磨');
  });

  testWidgets('没有可预填的配置时照常是空的', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [miaoaTagServiceProvider.overrideWithValue(_FakeTagService())],
      child: const MaterialApp(
        home: Scaffold(body: NewTaskWizard()),
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}

/// 向导里选完组就能当场写约束——不然只能等打完一遍、进任务再改一遍重打
void _promptInWizard() {
  testWidgets('向导里每个已选标签组后面有约束输入框', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [miaoaTagServiceProvider.overrideWithValue(_FakeTagService())],
      child: const MaterialApp(
        home: Scaffold(
          body: NewTaskWizard(
            prefillShotGroups: [TagGroupRef(id: 7, name: '植源场景')],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('tag-prompt-shot')), findsOneWidget,
        reason: '建任务时选完组当场就能写，第一次打标就用得上');
  });

  testWidgets('预填进来的约束显示在向导的输入框里', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [miaoaTagServiceProvider.overrideWithValue(_FakeTagService())],
      child: const MaterialApp(
        home: Scaffold(
          body: NewTaskWizard(
            prefillShotGroups: [TagGroupRef(id: 7, name: '植源场景')],
            prefillShotPrompt: '只判断台面与柜门',
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('只判断台面与柜门'), findsOneWidget);
  });

  testWidgets('没选组时不摆没有归属的输入框', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [miaoaTagServiceProvider.overrideWithValue(_FakeTagService())],
      child: const MaterialApp(home: Scaffold(body: NewTaskWizard())),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('tag-prompt-shot')), findsNothing);
  });
}

/// 向导里写的约束必须真的跟着结果出去——写完却没带走，等于白写
void _promptSurvivesStart() {
  testWidgets('在向导里写的约束会随结果一起带出去', (tester) async {
    NewTaskWizardResult? result;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        miaoaTagServiceProvider.overrideWithValue(_FakeTagService()),
        videoFilePickerProvider.overrideWithValue(() async => '/v/a.mp4'),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const Key('open'),
                onPressed: () async {
                  result = await showNewTaskWizard(
                    context,
                    prefillUnitGroups: const [TagGroupRef(id: 7, name: '植源场景')],
                    prefillShotGroups: const [TagGroupRef(id: 7, name: '植源场景')],
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

    await tester.tap(find.byKey(const Key('wizard-line-replace')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wizard-pick-local-file')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('tag-prompt-shot')), '只判断台面与柜门');
    await tester.pump();
    await tester.tap(find.byKey(const Key('wizard-start-btn')));
    await tester.pumpAndSettle();

    expect(result!.shotTagPrompt, '只判断台面与柜门');
  });
}
