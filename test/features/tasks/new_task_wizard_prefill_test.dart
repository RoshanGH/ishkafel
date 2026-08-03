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
  testWidgets('新建任务时预填上一条任务的标签组，连同它的打标约束', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [miaoaTagServiceProvider.overrideWithValue(_FakeTagService())],
      child: const MaterialApp(
        home: Scaffold(
          body: NewTaskWizard(
            prefillShotGroups: [
              TagGroupRef(id: 7, name: '植源场景', prompt: '只判断空间'),
            ],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('植源场景'), findsWidgets,
        reason: '同一个项目里连着建好几条任务是常态，每次重选四个组、'
            '重贴四段约束纯属折磨');
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
