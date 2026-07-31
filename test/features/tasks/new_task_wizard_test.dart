import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ffmpeg/process_runner.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart';
import 'package:ishkafel/core/models/tag_group_ref.dart';
import 'package:ishkafel/features/tasks/new_task_wizard/new_task_wizard.dart';
import 'package:ishkafel/features/tasks/new_task_wizard/wizard_providers.dart';

const _groupsJson = '''
[
  {"id":1279,"groupName":"衣清.消毒液","materialType":"STORYBOARD","tagType":"TENANT"},
  {"id":136,"groupName":"画面类型","materialType":"STORYBOARD","tagType":"AI"}
]
''';

const _tagsJson = '''
[
  {"id":1,"tagGroupId":1279,"tagName":"痛点引入"},
  {"id":2,"tagGroupId":1279,"tagName":"产品引入"},
  {"id":3,"tagGroupId":1279,"tagName":"功效演示"}
]
''';

/// 假 CLI：按子命令返回 fixture，绝不碰真实 miaoa
ProcessRunner fakeCli({
  String groups = _groupsJson,
  String tags = _tagsJson,
  int exitCode = 0,
  String stderr = '',
}) =>
    (_, args) async => ProcessResult(1, exitCode,
        args.contains('group') ? groups : tags, stderr);

/// 起不来的 CLI（未安装）
Future<ProcessResult> missingCli(String exe, List<String> args) async =>
    throw ProcessException(exe, args, 'No such file or directory', 2);

NewTaskWizardResult? lastResult;

Widget wrap({
  ProcessRunner? run,
  VideoFilePicker? picker,
}) {
  lastResult = null;
  return ProviderScope(
    overrides: [
      miaoaTagServiceProvider.overrideWithValue(
          MiaoaTagService(run: run ?? fakeCli())),
      videoFilePickerProvider
          .overrideWithValue(picker ?? () async => '/videos/滴露_测试片.mp4'),
    ],
    child: MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async =>
                  lastResult = await showNewTaskWizard(context),
              child: const Text('打开向导'),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> openWizard(WidgetTester tester, Widget app) async {
  await tester.pumpWidget(app);
  await tester.tap(find.text('打开向导'));
  await tester.pumpAndSettle();
}

Future<void> pickGroup(WidgetTester tester, Key fieldKey, String name) async {
  // 向导正文是可滚动区，测试窗口较矮时第二个下拉会在视口外
  await tester.ensureVisible(find.byKey(fieldKey));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(fieldKey));
  await tester.pumpAndSettle();
  await tester.tap(find.text(name).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('向导按设计稿分两步：成片来源 + 两个标签组', (tester) async {
    await openWizard(tester, wrap());

    expect(find.text('新建翻新任务'), findsOneWidget);
    expect(find.textContaining('第 1 步'), findsOneWidget);
    expect(find.textContaining('第 2 步'), findsOneWidget);
    expect(find.text('台词语义单元标签组'), findsOneWidget);
    expect(find.text('视觉镜头标签组'), findsOneWidget);
  });

  testWidgets('miaoa 拉片通道本期不做，但如实说明而不是留个点不动的控件',
      (tester) async {
    await openWizard(tester, wrap());

    expect(find.text('miaoa 成片库'), findsOneWidget);
    expect(find.textContaining('本期未开放'), findsOneWidget);
  });

  testWidgets('选择本地文件后显示文件名', (tester) async {
    await openWizard(tester, wrap());

    await tester.tap(find.byKey(const Key('wizard-pick-local-file')));
    await tester.pumpAndSettle();

    expect(find.textContaining('滴露_测试片'), findsOneWidget);
  });

  testWidgets('选中标签组后展开显示组内标签预览，让用户确认选对了组',
      (tester) async {
    await openWizard(tester, wrap());

    await pickGroup(tester, const Key('wizard-unit-tag-group'), '衣清.消毒液');

    expect(find.text('痛点引入'), findsOneWidget);
    expect(find.text('功效演示'), findsOneWidget);
  });

  group('miaoa 不可用时给可执行的中文引导（不是只写日志）', () {
    testWidgets('CLI 未安装 → 引导安装与 PATH，并给「重试」', (tester) async {
      await openWizard(tester, wrap(run: missingCli));

      expect(find.textContaining('PATH'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('未登录（401）→ 引导 miaoa auth login，且不自动重试',
        (tester) async {
      var calls = 0;
      await openWizard(tester, wrap(run: (_, _) async {
        calls++;
        return ProcessResult(1, 1, '', '401 Unauthorized');
      }));

      expect(find.textContaining('miaoa auth login'), findsOneWidget);
      expect(calls, 1, reason: '401 必须由用户手动重试，不能自动重试');
    });

    testWidgets('网络失败 → 引导检查网络', (tester) async {
      await openWizard(tester, wrap(
          run: (_, _) async =>
              ProcessResult(1, 1, '', 'dial tcp: connection refused')));

      expect(find.textContaining('网络'), findsOneWidget);
    });

    testWidgets('点「重试」会重新拉取标签组', (tester) async {
      var calls = 0;
      await openWizard(tester, wrap(run: (_, args) async {
        calls++;
        return calls == 1
            ? ProcessResult(1, 1, '', 'connection refused')
            : ProcessResult(1, 0, _groupsJson, '');
      }));
      expect(find.text('重试'), findsOneWidget);

      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();

      expect(calls, greaterThan(1));
      expect(find.text('台词语义单元标签组'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
    });

    testWidgets('标签组列表为空 → 说明后果与去哪儿建标签组', (tester) async {
      await openWizard(tester, wrap(run: fakeCli(groups: '[]')));

      expect(find.textContaining('没有可用的标签组'), findsOneWidget);
    });
  });

  group('「开始分析」的可用性与理由', () {
    testWidgets('没选文件、没选标签组时禁用，并说清为什么不能开始与不选的后果',
        (tester) async {
      await openWizard(tester, wrap());

      final button = tester.widget<FilledButton>(
          find.byKey(const Key('wizard-start-btn')));
      expect(button.onPressed, isNull);
      expect(find.textContaining('还需要'), findsOneWidget);
      expect(find.textContaining('候选素材'), findsOneWidget,
          reason: '要说清不选标签组的后果：阶段②检索不到候选素材');
    });

    testWidgets('只选了文件、标签组还没选齐时仍然禁用', (tester) async {
      await openWizard(tester, wrap());
      await tester.tap(find.byKey(const Key('wizard-pick-local-file')));
      await tester.pumpAndSettle();
      await pickGroup(tester, const Key('wizard-unit-tag-group'), '衣清.消毒液');

      expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('wizard-start-btn')))
              .onPressed,
          isNull);
      expect(find.textContaining('视觉镜头标签组'), findsWidgets);
    });

    testWidgets('选齐后可开始，返回文件与两个标签组', (tester) async {
      final app = wrap();
      await openWizard(tester, app);

      await tester.tap(find.byKey(const Key('wizard-pick-local-file')));
      await tester.pumpAndSettle();
      await pickGroup(tester, const Key('wizard-unit-tag-group'), '衣清.消毒液');
      await pickGroup(tester, const Key('wizard-shot-tag-group'), '画面类型');
      await tester.tap(find.byKey(const Key('wizard-start-btn')));
      await tester.pumpAndSettle();

      expect(lastResult, isNotNull);
      expect(lastResult!.filePath, '/videos/滴露_测试片.mp4');
      expect(lastResult!.unitTagGroup,
          const TagGroupRef(id: 1279, name: '衣清.消毒液'));
      expect(lastResult!.shotTagGroup, const TagGroupRef(id: 136, name: '画面类型'));
    });

    testWidgets('取消返回 null，不建任务', (tester) async {
      await openWizard(tester, wrap());

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(lastResult, isNull);
    });

    testWidgets('给出耗时预期（真机实测 96 秒素材约 1~2 分钟）', (tester) async {
      await openWizard(tester, wrap());

      expect(find.textContaining('分钟'), findsOneWidget);
    });
  });
}
