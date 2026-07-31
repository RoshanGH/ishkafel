import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ffmpeg/media_tools_locator.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/models/video_info.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';
import 'package:ishkafel/core/storage/task_repository.dart';
import 'package:ishkafel/features/tasks/environment_banner.dart';
import 'package:ishkafel/features/tasks/source_availability.dart';
import 'package:ishkafel/features/tasks/task_list_controller.dart';
import 'package:ishkafel/features/tasks/new_task_wizard/new_task_wizard.dart';
import 'package:ishkafel/features/tasks/new_task_wizard/wizard_providers.dart';
import 'package:ishkafel/features/tasks/task_list_page.dart';
import 'package:ishkafel/features/workbench/workbench_page.dart';

/// 内存假实现，避免 UI 测试碰文件系统
class InMemoryTaskRepository implements TaskRepository {
  final _store = <String, RenewTask>{};
  @override
  Future<List<RenewTask>> findAll() async {
    final list = _store.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  @override
  Future<RenewTask?> findById(String id) async => _store[id];
  @override
  Future<void> save(RenewTask task) async => _store[task.id] = task;
  @override
  Future<void> delete(String id) async => _store.remove(id);
}

/// findAll 可被挂起的假仓库：用于观察「重新加载进行中」这一中间态
class _BlockingRepository extends InMemoryTaskRepository {
  /// 非 null 时 findAll 会挂起，直到测试主动 complete
  Completer<void>? gate;

  @override
  Future<List<RenewTask>> findAll() async {
    final pending = gate;
    if (pending != null) await pending.future;
    return super.findAll();
  }
}

/// findAll 可被开关成「必定抛 I/O 异常」的假仓库
class _FailingRepository extends InMemoryTaskRepository {
  bool failFindAll = false;

  @override
  Future<List<RenewTask>> findAll() async {
    if (failFindAll) {
      throw const PathNotFoundException(
          '/tasks/x.json', OSError('No such file or directory', 2));
    }
    return super.findAll();
  }
}

/// 会上报「跳过了 N 个无法读取的任务文件」的假仓库
class _SkippingRepository extends InMemoryTaskRepository
    implements TaskLoadDiagnostics {
  @override
  final int skippedTaskFileCount;
  _SkippingRepository({required int skipped}) : skippedTaskFileCount = skipped;
}

RenewTask makeTask(String id, String name, RenewTaskStatus status) => RenewTask(
      id: id, name: name, sourcePath: '/v/$id.mp4', status: status,
      createdAt: DateTime.utc(2026, 7, 29), updatedAt: DateTime.utc(2026, 7, 29),
    );

Widget wrap(TaskRepository repo, {List<Override> overrides = const []}) =>
    ProviderScope(
      overrides: [
        taskRepositoryProvider.overrideWithValue(repo),
        // 默认假定源文件都在：测试不该依赖真实文件系统
        fileExistsProbeProvider.overrideWithValue((_) async => true),
        // 单测零真实依赖：绝不真的去调 miaoa CLI 或弹系统文件框
        miaoaTagServiceProvider.overrideWithValue(MiaoaTagService(
            run: (_, _) async => ProcessResult(1, 0, '[]', ''))),
        videoFilePickerProvider.overrideWithValue(() async => null),
        ...overrides,
      ],
      child: const MaterialApp(home: TaskListPage()),
    );

void main() {
  testWidgets('空状态显示引导文案', (tester) async {
    await tester.pumpWidget(wrap(InMemoryTaskRepository()));
    await tester.pumpAndSettle();
    expect(find.textContaining('还没有任务'), findsOneWidget);
  });

  testWidgets('有任务时按卡片渲染名称与状态徽标', (tester) async {
    final repo = InMemoryTaskRepository();
    await repo.save(makeTask('a', '滴露_植源喷雾', RenewTaskStatus.picking));
    await repo.save(makeTask('b', '卫仕洗衣液', RenewTaskStatus.exported));
    await tester.pumpWidget(wrap(repo));
    await tester.pumpAndSettle();
    expect(find.text('滴露_植源喷雾'), findsOneWidget);
    expect(find.text('选材中'), findsOneWidget);
    expect(find.text('卫仕洗衣液'), findsOneWidget);
    expect(find.text('已导出'), findsOneWidget);
  });

  testWidgets('点「新建任务」弹出新建任务向导（不再是裸文件选择框）', (tester) async {
    await tester.pumpWidget(wrap(InMemoryTaskRepository()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('新建任务'));
    await tester.pumpAndSettle();

    expect(find.byType(NewTaskWizard), findsOneWidget);
    expect(find.text('新建翻新任务'), findsOneWidget);
  });

  group('重新加载不闪白（保存后整页 spinner）', () {
    testWidgets('重新加载期间旧列表仍然可见，且不出现整页 spinner', (tester) async {
      final repo = _BlockingRepository();
      await repo.save(makeTask('k1', '已有任务', RenewTaskStatus.awaitingCut));
      await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();
      expect(find.text('已有任务'), findsOneWidget);

      final container = ProviderScope.containerOf(
          tester.element(find.byType(TaskListPage)));
      final gate = Completer<void>();
      repo.gate = gate;
      final reloading = container.read(taskListProvider.notifier).reload();

      // 重新加载已开始但未完成：旧数据必须还在，不能整页换成 spinner
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: '保存一条任务不应让整页任务网格闪白');
      expect(find.text('已有任务'), findsOneWidget);

      gate.complete();
      await reloading;
      await tester.pumpAndSettle();
      expect(find.text('已有任务'), findsOneWidget);
    });

    testWidgets('首次装载仍展示 spinner（此时无旧数据可保留）', (tester) async {
      final repo = _BlockingRepository()..gate = Completer<void>();
      await tester.pumpWidget(wrap(repo));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      repo.gate!.complete();
      await tester.pumpAndSettle();
    });
  });

  group('运行环境横幅（ffmpeg/ffprobe 缺失）', () {
    testWidgets('未检测到 ffmpeg/ffprobe 时常驻横幅给出中文安装引导', (tester) async {
      await tester.pumpWidget(wrap(
        InMemoryTaskRepository(),
        overrides: [
          mediaToolsStatusProvider.overrideWithValue(
              const MediaToolsStatus(ffmpegPath: null, ffprobePath: null)),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('未检测到'), findsOneWidget);
      expect(find.textContaining('brew install ffmpeg'), findsOneWidget);
    });

    testWidgets('工具就绪时不显示横幅', (tester) async {
      await tester.pumpWidget(wrap(
        InMemoryTaskRepository(),
        overrides: [
          mediaToolsStatusProvider.overrideWithValue(const MediaToolsStatus(
              ffmpegPath: '/opt/homebrew/bin/ffmpeg',
              ffprobePath: '/opt/homebrew/bin/ffprobe')),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('未检测到'), findsNothing);
    });
  });

  group('任务卡点击路由', () {
    RenewTask makeCuttableTask(RenewTaskStatus status) => RenewTask(
          id: 'r1',
          name: '可进入审片台的任务',
          sourcePath: '/v/r1.mp4',
          status: status,
          createdAt: DateTime.utc(2026, 7, 29),
          updatedAt: DateTime.utc(2026, 7, 29),
          units: [
            SemanticUnit(
              index: 0,
              startMs: 0,
              endMs: 1000,
              transcript: 't',
              shots: const [Shot(startMs: 0, endMs: 1000)],
            ),
          ],
          videoInfo: const VideoInfo(
            width: 1080,
            height: 1920,
            duration: Duration(milliseconds: 1000),
            fps: 30,
            fileSizeBytes: 10,
          ),
        );

    testWidgets('awaitingCut 且有 units 时点击进入审片台', (tester) async {
      final repo = InMemoryTaskRepository();
      await repo.save(makeCuttableTask(RenewTaskStatus.awaitingCut));
      await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.text('可进入审片台的任务'));
      await tester.pumpAndSettle();

      expect(find.byType(WorkbenchPage), findsOneWidget);
    });

    testWidgets('picking 状态点击也可进入审片台（允许回看）', (tester) async {
      final repo = InMemoryTaskRepository();
      await repo.save(makeCuttableTask(RenewTaskStatus.picking));
      await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.text('可进入审片台的任务'));
      await tester.pumpAndSettle();

      expect(find.byType(WorkbenchPage), findsOneWidget);
    });

    testWidgets('exported 状态点击不进入审片台（评审 Important 1：路由口径收回）',
        (tester) async {
      final repo = InMemoryTaskRepository();
      await repo.save(makeCuttableTask(RenewTaskStatus.exported));
      await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.text('可进入审片台的任务'));
      await tester.pumpAndSettle();

      expect(find.byType(WorkbenchPage), findsNothing);
      expect(find.textContaining('已导出的任务'), findsOneWidget);
    });

    testWidgets('历史遗留的非法帧率任务点击不进入审片台（否则按帧计算会红屏）',
        (tester) async {
      final repo = InMemoryTaskRepository();
      await repo.save(makeCuttableTask(RenewTaskStatus.awaitingCut).copyWith(
        videoInfo: const VideoInfo(
          width: 1080,
          height: 1920,
          duration: Duration(milliseconds: 1000),
          fps: 0,
          fileSizeBytes: 10,
        ),
      ));
      await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.text('可进入审片台的任务'));
      await tester.pumpAndSettle();

      expect(find.byType(WorkbenchPage), findsNothing);
      expect(find.textContaining('帧率'), findsOneWidget);
    });

    testWidgets('启动后装载到的 analyzing 任务被判为中断，点击给出中断原因与重试入口',
        (tester) async {
      final repo = InMemoryTaskRepository();
      await repo.save(makeTask('a2', '分析中的任务', RenewTaskStatus.analyzing));
      await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.text('分析中的任务'));
      await tester.pumpAndSettle();

      expect(find.byType(WorkbenchPage), findsNothing);
      expect(find.textContaining('中断'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });
  });

  group('AI 未配置的常驻提示', () {
    testWidgets('分析管线未配置时列表页常驻横幅说明后果', (tester) async {
      await tester.pumpWidget(wrap(InMemoryTaskRepository()));
      await tester.pumpAndSettle();

      expect(find.textContaining('尚未配置'), findsOneWidget);
    });

    testWidgets('点「重试」时给出「AI 服务未配置」的即时反馈', (tester) async {
      final repo = InMemoryTaskRepository();
      await repo
          .save(makeTask('f2', '失败任务', RenewTaskStatus.analyzing)
              .copyWith(analysisError: '上次分析被中断'));
      await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.text('失败任务'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();

      expect(find.textContaining('AI 服务未配置'), findsWidgets);
    });
  });

  group('装载失败要说人话且能重试（Important 7）', () {
    testWidgets('首次装载失败：不摊原始异常，给中文说明与「重试」按钮', (tester) async {
      final repo = _FailingRepository()..failFindAll = true;
      await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();

      expect(find.textContaining('PathNotFoundException'), findsNothing,
          reason: '异常类名与 errno 只该进日志');
      expect(find.textContaining('加载失败：'), findsNothing);
      expect(find.textContaining('任务列表读取失败'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '重试'), findsOneWidget);

      // 点「重试」应真的重新装载，恢复正常后列表出得来
      repo.failFindAll = false;
      await repo.save(makeTask('ok', '恢复的任务', RenewTaskStatus.awaitingCut));
      await tester.tap(find.widgetWithText(FilledButton, '重试'));
      await tester.pumpAndSettle();

      expect(find.text('恢复的任务'), findsOneWidget);
    });

    testWidgets('已有列表时刷新失败：列表继续显示，顶部横幅给可重试的提示', (tester) async {
      final repo = _FailingRepository();
      await repo.save(makeTask('k1', '已有任务', RenewTaskStatus.awaitingCut));
      await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
          tester.element(find.byType(TaskListPage)));
      repo.failFindAll = true;
      await container.read(taskListProvider.notifier).reload();
      await tester.pumpAndSettle();

      expect(find.text('已有任务'), findsOneWidget,
          reason: '刷新失败不该把已经显示出来的任务网格清空');
      expect(find.textContaining('任务列表读取失败'), findsOneWidget);
    });
  });

  group('损坏任务文件的可见提示', () {
    testWidgets('跳过无法读取的任务文件时列表页顶部给出提示', (tester) async {
      final repo = _SkippingRepository(skipped: 2);
      await repo.save(makeTask('ok', '正常任务', RenewTaskStatus.awaitingCut));
      await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();

      expect(find.textContaining('2 个'), findsOneWidget);
      expect(find.textContaining('无法读取'), findsOneWidget);
    });

    testWidgets('没有跳过时不显示提示', (tester) async {
      final repo = _SkippingRepository(skipped: 0);
      await repo.save(makeTask('ok', '正常任务', RenewTaskStatus.awaitingCut));
      await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();

      expect(find.textContaining('无法读取'), findsNothing);
    });
  });

  group('源文件已不存在时，列表与卡片要说人话', () {
    RenewTask makeOpenableTask() => RenewTask(
          id: 's1',
          name: '素材已被删除的任务',
          sourcePath: '/v/已删除.mp4',
          status: RenewTaskStatus.awaitingCut,
          createdAt: DateTime.utc(2026, 7, 29),
          updatedAt: DateTime.utc(2026, 7, 29),
          units: [
            SemanticUnit(
              index: 0,
              startMs: 0,
              endMs: 1000,
              transcript: 't',
              shots: const [Shot(startMs: 0, endMs: 1000)],
            ),
          ],
          videoInfo: const VideoInfo(
            width: 1080,
            height: 1920,
            duration: Duration(milliseconds: 1000),
            fps: 30,
            fileSizeBytes: 10,
          ),
        );

    Override missingSourceOverride() =>
        fileExistsProbeProvider.overrideWithValue((_) async => false);

    testWidgets('探测到源文件缺失时卡片给出可见标记', (tester) async {
      final repo = InMemoryTaskRepository();
      await repo.save(makeOpenableTask());
      await tester.pumpWidget(
          wrap(repo, overrides: [missingSourceOverride()]));
      await tester.pumpAndSettle();

      expect(find.text('源文件缺失'), findsOneWidget);
    });

    testWidgets('点击源文件缺失的任务不进入审片台，给出可操作的中文说明', (tester) async {
      final repo = InMemoryTaskRepository();
      await repo.save(makeOpenableTask());
      await tester.pumpWidget(
          wrap(repo, overrides: [missingSourceOverride()]));
      await tester.pumpAndSettle();

      await tester.tap(find.text('素材已被删除的任务'));
      await tester.pumpAndSettle();

      expect(find.byType(WorkbenchPage), findsNothing);
      expect(find.textContaining('源文件已不存在'), findsOneWidget);
    });

    testWidgets('缓存说「在」但文件已被删掉：点击时实时校验必须拦住入口（Important 4）',
        (tester) async {
      final repo = InMemoryTaskRepository();
      await repo.save(makeOpenableTask());
      var exists = true;
      await tester.pumpWidget(wrap(repo, overrides: [
        fileExistsProbeProvider.overrideWithValue((_) async => exists),
      ]));
      await tester.pumpAndSettle();
      expect(find.text('源文件缺失'), findsNothing);

      // 用户在 Finder 里删掉了源视频；没有导入/删除/重命名/分析完成，
      // 缓存不会重算，这条仍被当作「存在」
      exists = false;
      await tester.tap(find.text('素材已被删除的任务'));
      await tester.pumpAndSettle();

      expect(find.byType(WorkbenchPage), findsNothing,
          reason: '进去只会是播放器黑屏 + 两条辅助轨报失败');
      expect(find.textContaining('源文件已不存在'), findsOneWidget);
      expect(find.text('源文件缺失'), findsOneWidget,
          reason: '实时校验的结果要回灌缓存，列表上的红标跟着更新');
    });

    testWidgets('文件放回原位后不必重启应用：点击时实时校验放行（Important 4）',
        (tester) async {
      final repo = InMemoryTaskRepository();
      await repo.save(makeOpenableTask());
      var exists = false;
      await tester.pumpWidget(wrap(repo, overrides: [
        fileExistsProbeProvider.overrideWithValue((_) async => exists),
      ]));
      await tester.pumpAndSettle();
      expect(find.text('源文件缺失'), findsOneWidget);

      exists = true;
      await tester.tap(find.text('素材已被删除的任务'));
      await tester.pumpAndSettle();

      expect(find.byType(WorkbenchPage), findsOneWidget,
          reason: '文件已经放回来了，入口不该继续被挡');
    });

    testWidgets('应用重新激活时重算缓存（在 Finder 里改动文件后回到应用即可见）',
        (tester) async {
      final repo = InMemoryTaskRepository();
      await repo.save(makeOpenableTask());
      var exists = true;
      await tester.pumpWidget(wrap(repo, overrides: [
        fileExistsProbeProvider.overrideWithValue((_) async => exists),
      ]));
      await tester.pumpAndSettle();
      expect(find.text('源文件缺失'), findsNothing);

      exists = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(find.text('源文件缺失'), findsOneWidget);
    });

    testWidgets('源文件存在性只在列表变化时探测一次，不随每帧重复（否则又是逐帧同步 IO）',
        (tester) async {
      final repo = InMemoryTaskRepository();
      await repo.save(makeOpenableTask());
      var probeCount = 0;
      await tester.pumpWidget(wrap(repo, overrides: [
        fileExistsProbeProvider.overrideWithValue((_) async {
          probeCount++;
          return true;
        }),
      ]));
      await tester.pumpAndSettle();
      final afterLoad = probeCount;

      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(afterLoad, 1, reason: '一条任务只该探一次');
      expect(probeCount, afterLoad, reason: '重绘不应重新探测文件系统');
    });
  });

  group('任务卡菜单：删除 / 重命名 / 重新分析', () {
    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
    }

    testWidgets('「更多」按钮弹出三项菜单', (tester) async {
      final repo = InMemoryTaskRepository();
      await repo.save(makeTask('m1', '待办任务', RenewTaskStatus.awaitingCut));
      await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();

      await openMenu(tester);

      expect(find.text('重命名'), findsOneWidget);
      expect(find.text('重新分析'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
    });

    testWidgets('删除需要二次确认，确认后任务消失', (tester) async {
      final repo = InMemoryTaskRepository();
      await repo.save(makeTask('m2', '要删的任务', RenewTaskStatus.awaitingCut));
      await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();

      await openMenu(tester);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      // 确认对话框：任务仍在
      expect(find.textContaining('无法撤销'), findsOneWidget);
      expect(await repo.findById('m2'), isNotNull);

      await tester.tap(find.widgetWithText(TextButton, '删除'));
      await tester.pumpAndSettle();

      expect(await repo.findById('m2'), isNull);
      expect(find.text('要删的任务'), findsNothing);
    });

    testWidgets('删除确认框点「取消」则任务保留', (tester) async {
      final repo = InMemoryTaskRepository();
      await repo.save(makeTask('m3', '保留任务', RenewTaskStatus.awaitingCut));
      await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();

      await openMenu(tester);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();

      expect(await repo.findById('m3'), isNotNull);
      expect(find.text('保留任务'), findsOneWidget);
    });

    testWidgets('重命名对话框保存后卡片显示新名称', (tester) async {
      final repo = InMemoryTaskRepository();
      await repo.save(makeTask('m4', '旧名字', RenewTaskStatus.awaitingCut));
      await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();

      await openMenu(tester);
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '新名字');
      await tester.tap(find.widgetWithText(TextButton, '保存'));
      await tester.pumpAndSettle();

      expect((await repo.findById('m4'))!.name, '新名字');
      expect(find.text('新名字'), findsOneWidget);
    });

    testWidgets('点「重新分析」不崩溃（分析管线未配置场景）', (tester) async {
      final repo = InMemoryTaskRepository();
      await repo.save(makeTask('m5', '重跑任务', RenewTaskStatus.awaitingCut));
      await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();

      await openMenu(tester);
      await tester.tap(find.text('重新分析'));
      await tester.pumpAndSettle();
    });
  });

  group('分析失败反馈', () {
    RenewTask makeFailedTask() => makeTask('f1', '失败任务', RenewTaskStatus.analyzing)
        .copyWith(analysisError: '网络连接超时，请检查凭据配置');

    testWidgets('分析失败任务显示红色「分析失败」徽标，优先于状态徽标', (tester) async {
      final repo = InMemoryTaskRepository();
      await repo.save(makeFailedTask());
      await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();

      expect(find.text('分析失败'), findsOneWidget);
      // 状态徽标文案「分析中」不应再出现（被失败徽标顶替）
      expect(find.text('分析中'), findsNothing);
    });

    testWidgets('点击失败任务卡不进入审片台，显示失败原因与「重试」action', (tester) async {
      final repo = InMemoryTaskRepository();
      await repo.save(makeFailedTask());
      await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.text('失败任务'));
      await tester.pumpAndSettle();

      expect(find.byType(WorkbenchPage), findsNothing);
      expect(find.textContaining('网络连接超时，请检查凭据配置'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);

      // 点击「重试」不应崩溃（pipeline 未配置场景，controller 内部会直接返回）
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
    });
  });
}
