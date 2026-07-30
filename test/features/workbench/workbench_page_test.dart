import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/audio_extractor.dart';
import 'package:ishkafel/core/ffmpeg/thumbnail_service.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/models/video_info.dart';
import 'package:ishkafel/core/playback/playback_controller.dart';
import 'package:ishkafel/core/storage/task_repository.dart';
import 'package:ishkafel/features/tasks/task_list_controller.dart';
import 'package:ishkafel/features/workbench/inspector_panel.dart';
import 'package:ishkafel/features/workbench/player_panel.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_view.dart';
import 'package:ishkafel/features/workbench/timeline_media_builder.dart';
import 'package:ishkafel/features/workbench/unit_list_panel.dart';
import 'package:ishkafel/features/workbench/workbench_page.dart';

/// 内存假仓库，避免测试碰真实文件系统（沿用 task_list_page_test.dart 的做法）
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

/// 假抽帧/音频服务：不触发真实 ffmpeg，写出最小可用的假产物文件
TimelineMediaBuilder _fakeMediaBuilder() {
  final thumbnails = ThumbnailService(run: (_, args) async {
    final outPath = args.last;
    await File(outPath).writeAsBytes(List<int>.filled(600, 1));
    return ProcessResult(1, 0, '', '');
  });
  final audio = AudioExtractor(run: (_, args) async {
    final outPath = args.last;
    await File(outPath).writeAsBytes(List<int>.filled(64, 0));
    return ProcessResult(1, 0, '', '');
  });
  return TimelineMediaBuilder(thumbnails: thumbnails, audio: audio);
}

List<SemanticUnit> _fixtureUnits() => [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 2000,
        transcript: '第一句台词',
        shots: const [Shot(startMs: 0, endMs: 2000)],
      ),
      SemanticUnit(
        index: 1,
        startMs: 2000,
        endMs: 4000,
        transcript: '第二句台词',
        shots: const [Shot(startMs: 2000, endMs: 4000)],
      ),
    ];

/// 真机缺陷复现数据：末单元只有 53ms，在时间线上宽度不足 1px。
/// 这类「亚像素」单元是编辑期把边界拖到极右端后确认落库产生的合法数据。
List<SemanticUnit> _unitsWithSliverTail() => const [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 92200,
        transcript: '主体台词',
        shots: [Shot(startMs: 0, endMs: 92200)],
      ),
      SemanticUnit(
        index: 1,
        startMs: 92200,
        endMs: 92253,
        transcript: '极窄末单元',
        shots: [Shot(startMs: 92200, endMs: 92253)],
      ),
    ];

RenewTask _fixtureTask({RenewTaskStatus status = RenewTaskStatus.awaitingCut}) =>
    RenewTask(
      id: 'wb-1',
      name: '滴露_植源喷雾',
      sourcePath: '/videos/wb-1.mp4',
      status: status,
      createdAt: DateTime.utc(2026, 7, 29),
      updatedAt: DateTime.utc(2026, 7, 29),
      units: _fixtureUnits(),
      videoInfo: const VideoInfo(
        width: 1080,
        height: 1920,
        duration: Duration(milliseconds: 4000),
        fps: 30,
        fileSizeBytes: 1000,
      ),
    );

/// 把 WorkbenchPage 挂在一个可返回的「列表页」之下，便于断言 pop 行为
Widget _wrapWithNavigator({
  required RenewTask task,
  required TaskRepository repo,
  required FakePlaybackController playback,
}) {
  return ProviderScope(
    overrides: [taskRepositoryProvider.overrideWithValue(repo)],
    child: MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const Key('open-workbench'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => WorkbenchPage(
                  task: task,
                  playbackFactory: () => playback,
                  mediaBuilder: _fakeMediaBuilder(),
                ),
              )),
              child: const Text('列表页占位'),
            ),
          ),
        ),
      ),
    ),
  );
}

/// 模拟按下 ⌘Z（撤销）/ ⇧⌘Z（重做）：分别按下修饰键再敲 Z，再释放修饰键，
/// 与真实键盘按键顺序一致，确保 SingleActivator 的 meta/shift 判定命中。
Future<void> _pressUndoShortcut(WidgetTester tester, {bool redo = false}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  if (redo) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
  if (redo) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
}

void main() {
  late InMemoryTaskRepository repo;
  late FakePlaybackController playback;
  late RenewTask task;

  setUp(() {
    repo = InMemoryTaskRepository();
    playback = FakePlaybackController();
    task = _fixtureTask();
  });

  testWidgets('①渲染三栏（单元列表/播放器/检查器）与时间线', (tester) async {
    await repo.save(task);
    await tester.pumpWidget(_wrapWithNavigator(task: task, repo: repo, playback: playback));
    await tester.tap(find.byKey(const Key('open-workbench')));
    await tester.pumpAndSettle();

    expect(find.byType(UnitListPanel), findsOneWidget);
    expect(find.byType(PlayerPanel), findsOneWidget);
    expect(find.byType(InspectorPanel), findsOneWidget);
    expect(find.byType(TimelineView), findsOneWidget);
    expect(find.text('第一句台词'), findsOneWidget);
    expect(find.text('确认切分，进入替换选材'), findsOneWidget);
  });

  testWidgets('②点击确认：仓库任务 status=picking 且 units 为编辑后值，页面 pop', (tester) async {
    await repo.save(task);
    await tester.pumpWidget(_wrapWithNavigator(task: task, repo: repo, playback: playback));
    await tester.tap(find.byKey(const Key('open-workbench')));
    await tester.pumpAndSettle();

    // 选中第二个单元并把其起始边界前移 1 帧（产生一次合法编辑）
    await tester.tap(find.byKey(const Key('unit-row-1')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('inspector-start-minus')));
    await tester.pump();

    await tester.tap(find.byKey(const Key('workbench-confirm-btn')));
    await tester.pumpAndSettle();

    // 已 pop 回列表占位页
    expect(find.text('列表页占位'), findsOneWidget);

    final saved = await repo.findById('wb-1');
    expect(saved!.status, RenewTaskStatus.picking);
    expect(saved.units, isNot(equals(task.units)));
    expect(saved.units![1].startMs, lessThan(2000));
  });

  testWidgets('③编辑后返回弹出确认对话框（取消/放弃修改）', (tester) async {
    await repo.save(task);
    await tester.pumpWidget(_wrapWithNavigator(task: task, repo: repo, playback: playback));
    await tester.tap(find.byKey(const Key('open-workbench')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('unit-row-1')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('inspector-start-minus')));
    await tester.pump();

    await tester.tap(find.byKey(const Key('workbench-back-btn')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('leave-dialog-cancel')), findsOneWidget);
    expect(find.byKey(const Key('leave-dialog-discard')), findsOneWidget);
    expect(find.byKey(const Key('leave-dialog-draft')), findsOneWidget);

    // 取消：对话框关闭，仍停留在审片台
    await tester.tap(find.byKey(const Key('leave-dialog-cancel')));
    await tester.pumpAndSettle();
    expect(find.byType(WorkbenchPage), findsOneWidget);

    // 再次返回并放弃修改：pop 且仓库未落库编辑
    await tester.tap(find.byKey(const Key('workbench-back-btn')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('leave-dialog-discard')));
    await tester.pumpAndSettle();

    expect(find.text('列表页占位'), findsOneWidget);
    final saved = await repo.findById('wb-1');
    expect(saved!.status, RenewTaskStatus.awaitingCut);
    expect(saved.units, task.units);
  });

  testWidgets('④空格键切换播放/暂停', (tester) async {
    await repo.save(task);
    await tester.pumpWidget(_wrapWithNavigator(task: task, repo: repo, playback: playback));
    await tester.tap(find.byKey(const Key('open-workbench')));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(playback.calls, contains('play()'));

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(playback.calls, contains('pause()'));
  });

  testWidgets('⑤ −1帧/+1帧 按钮调用 stepFrames', (tester) async {
    await repo.save(task);
    await tester.pumpWidget(_wrapWithNavigator(task: task, repo: repo, playback: playback));
    await tester.tap(find.byKey(const Key('open-workbench')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('player-step-forward')));
    await tester.pump();
    expect(playback.calls, contains('stepFrames(1, 30.0)'));

    await tester.tap(find.byKey(const Key('player-step-back')));
    await tester.pump();
    expect(playback.calls, contains('stepFrames(-1, 30.0)'));
  });

  testWidgets('播放器初始化异常时不崩溃且显示可见提示（评审 Important 1）', (tester) async {
    await repo.save(task);
    await tester.pumpWidget(ProviderScope(
      overrides: [taskRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
        home: WorkbenchPage(
          task: task,
          playbackFactory: () => throw Exception(
              'MediaKit.ensureInitialized must be called before using any API from package:media_kit.'),
          mediaBuilder: _fakeMediaBuilder(),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('播放器不可用，当前仅可编辑切分'), findsOneWidget);
    // 页面其余交互仍可用：三栏与时间线照常渲染
    expect(find.byType(UnitListPanel), findsOneWidget);
    expect(find.byType(TimelineView), findsOneWidget);
  });

  testWidgets('播放器工厂抛出 Error（编程错误）时不被静默吞掉（评审 Important 1 收窄捕获）',
      (tester) async {
    await repo.save(task);
    await tester.pumpWidget(ProviderScope(
      overrides: [taskRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
        home: WorkbenchPage(
          task: task,
          playbackFactory: () => throw StateError('模拟编程错误（非 media_kit 异常）'),
          mediaBuilder: _fakeMediaBuilder(),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // `on Exception catch` 不捕获 Error 子类，异常应继续抛出（被 Flutter
    // 框架捕获为 FlutterError 并可经 tester.takeException 取回），而不是
    // 被静默包装成「播放器不可用」提示
    expect(tester.takeException(), isA<StateError>());
    expect(find.text('播放器不可用，当前仅可编辑切分'), findsNothing);
  });

  testWidgets('焦点在单元列表行（非 PlayerPanel）时按空格 → playback.isPlaying 仍能切换（评审 Important 2）',
      (tester) async {
    await repo.save(task);
    await tester.pumpWidget(_wrapWithNavigator(task: task, repo: repo, playback: playback));
    await tester.tap(find.byKey(const Key('open-workbench')));
    await tester.pumpAndSettle();

    // 显式把键盘焦点移到单元列表某一行的内部 Focus 节点（而非 PlayerPanel）。
    // 注：flutter_test 里 tester.tap() 并不会像真实桌面鼠标点击那样把焦点
    // 转移到 InkWell/IconButton 等普通可聚焦控件（已用独立探针验证），因此
    // 用 Focus.of(descendantContext).requestFocus() 显式复现"焦点落在别处"
    // 这一评审场景，而不是依赖 tap 的副作用。
    final rowTextContext = tester.element(find.text('第二句台词'));
    Focus.of(rowTextContext).requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(playback.calls, contains('play()'));

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(playback.calls, contains('pause()'));
  });

  testWidgets('焦点在台词 TextField 时按空格 → playback 未被触发（评审 Important 2）',
      (tester) async {
    await repo.save(task);
    await tester.pumpWidget(_wrapWithNavigator(task: task, repo: repo, playback: playback));
    await tester.tap(find.byKey(const Key('open-workbench')));
    await tester.pumpAndSettle();

    // 选中单元后让台词输入框真正获得键盘焦点（用 showKeyboard 而非 tap，
    // 避免坐标命中问题，且与 TextField 在真实场景下的聚焦方式一致）
    await tester.tap(find.byKey(const Key('unit-row-0')));
    await tester.pump();
    await tester.showKeyboard(find.byKey(const Key('inspector-transcript-field')));
    await tester.pump();

    final callsBefore = List<String>.from(playback.calls);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();

    // 播放未被触发（calls 未新增 play()/pause()）——即便 flutter_test 的
    // sendKeyEvent 并不会像真实平台 IME 那样把空格真正打进文本框（已用独立
    // 探针验证：字符输入走 TextInput 通道而非原始按键事件），本用例仍能
    // 忠实验证"页面级快捷键在文本框聚焦时必须放行按键、不拦截"这一核心诉求。
    expect(playback.calls, callsBefore);
  });

  testWidgets('任务缺少 units 时显示错误占位而非崩溃', (tester) async {
    final brokenTask = RenewTask(
      id: 'wb-broken',
      name: '未分析任务',
      sourcePath: '/videos/wb-broken.mp4',
      status: RenewTaskStatus.awaitingCut,
      createdAt: DateTime.utc(2026, 7, 29),
      updatedAt: DateTime.utc(2026, 7, 29),
    );
    await repo.save(brokenTask);
    await tester.pumpWidget(_wrapWithNavigator(task: brokenTask, repo: repo, playback: playback));
    await tester.tap(find.byKey(const Key('open-workbench')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(PlayerPanel), findsNothing);
  });

  group('undo/redo（评审 Critical 2：全局无 UI 入口）', () {
    testWidgets('按 ⌘Z 撤销一次编辑：确认后落库为编辑前的原始 units', (tester) async {
      await repo.save(task);
      await tester.pumpWidget(_wrapWithNavigator(task: task, repo: repo, playback: playback));
      await tester.tap(find.byKey(const Key('open-workbench')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('unit-row-1')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('inspector-start-minus')));
      await tester.pump();

      await _pressUndoShortcut(tester);
      await tester.pump();

      await tester.tap(find.byKey(const Key('workbench-confirm-btn')));
      await tester.pumpAndSettle();

      final saved = await repo.findById('wb-1');
      expect(saved!.units, task.units, reason: '⌘Z 应已把编辑撤销回原始状态');
    });

    testWidgets('canUndo=false 时按 ⌘Z 不崩溃', (tester) async {
      await repo.save(task);
      await tester.pumpWidget(_wrapWithNavigator(task: task, repo: repo, playback: playback));
      await tester.tap(find.byKey(const Key('open-workbench')));
      await tester.pumpAndSettle();

      await _pressUndoShortcut(tester);
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byType(TimelineView), findsOneWidget);
    });

    testWidgets('台词 TextField 获焦时按 ⌘Z 不触发编辑器 undo（让路给系统文本撤销）',
        (tester) async {
      await repo.save(task);
      await tester.pumpWidget(_wrapWithNavigator(task: task, repo: repo, playback: playback));
      await tester.tap(find.byKey(const Key('open-workbench')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('unit-row-1')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('inspector-start-minus')));
      await tester.pump();

      await tester.showKeyboard(find.byKey(const Key('inspector-transcript-field')));
      await tester.pump();
      await _pressUndoShortcut(tester);
      await tester.pump();

      await tester.tap(find.byKey(const Key('workbench-confirm-btn')));
      await tester.pumpAndSettle();

      final saved = await repo.findById('wb-1');
      expect(saved!.units, isNot(equals(task.units)),
          reason: '焦点在文本框时 ⌘Z 不应触发编辑器 undo，编辑应保留');
    });

    testWidgets('时间线工具条撤销/重做按钮：禁用态正确且点击生效', (tester) async {
      await repo.save(task);
      await tester.pumpWidget(_wrapWithNavigator(task: task, repo: repo, playback: playback));
      await tester.tap(find.byKey(const Key('open-workbench')));
      await tester.pumpAndSettle();

      IconButton undoBtn() =>
          tester.widget<IconButton>(find.byKey(const Key('timeline-undo-btn')));
      IconButton redoBtn() =>
          tester.widget<IconButton>(find.byKey(const Key('timeline-redo-btn')));

      expect(undoBtn().onPressed, isNull, reason: '尚无编辑，撤销按钮应禁用');
      expect(redoBtn().onPressed, isNull, reason: '尚无撤销，重做按钮应禁用');

      await tester.tap(find.byKey(const Key('unit-row-1')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('inspector-start-minus')));
      await tester.pump();

      expect(undoBtn().onPressed, isNotNull, reason: '编辑后撤销按钮应可用');
      expect(redoBtn().onPressed, isNull);

      await tester.tap(find.byKey(const Key('timeline-undo-btn')));
      await tester.pump();

      expect(undoBtn().onPressed, isNull, reason: '撤销到底后按钮应重新禁用');
      expect(redoBtn().onPressed, isNotNull, reason: '撤销后重做按钮应可用');

      await tester.tap(find.byKey(const Key('workbench-confirm-btn')));
      await tester.pumpAndSettle();

      final saved = await repo.findById('wb-1');
      expect(saved!.units, task.units, reason: '按钮撤销应与快捷键撤销效果一致');
    });
  });

  group('只读回看模式（评审 Important 1：picking 状态不可再编辑已确认数据）', () {
    testWidgets('检查器步进/台词/拆分/合并按钮禁用，直接返回不弹保存草稿确认框', (tester) async {
      final pickingTask = _fixtureTask(status: RenewTaskStatus.picking);
      await repo.save(pickingTask);
      await tester.pumpWidget(
          _wrapWithNavigator(task: pickingTask, repo: repo, playback: playback));
      await tester.tap(find.byKey(const Key('open-workbench')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('unit-row-0')));
      await tester.pump();

      final endPlus = tester
          .widget<InkWell>(find.byKey(const Key('inspector-end-plus')));
      expect(endPlus.onTap, isNull, reason: '只读模式下步进按钮应禁用');

      final field = tester.widget<TextField>(
          find.byKey(const Key('inspector-transcript-field')));
      expect(field.enabled, isFalse, reason: '只读模式下台词框应禁用');

      final splitBtn =
          tester.widget<InkWell>(find.byKey(const Key('inspector-split-btn')));
      expect(splitBtn.onTap, isNull, reason: '只读模式下拆分按钮应禁用');

      // 无 dirty 可言，返回应直接 pop，不弹「保存草稿」确认框
      await tester.tap(find.byKey(const Key('workbench-back-btn')));
      await tester.pumpAndSettle();
      expect(find.text('列表页占位'), findsOneWidget);
    });

    // 注：本用例只覆盖"点选列表行浏览 + 返回不写回仓库"这一行为——它
    // 不做任何拖拽，标题曾误写为"时间线拖拽边界不改变仓库中的 units"，
    // 名不副实（评审 Minor D）。真正的"只读模式下拖拽边界不改变 units"
    // 覆盖在 timeline_view_test.dart 的 readOnly 分组（4 条用例），此处
    // 不重复。
    testWidgets('只读模式下浏览（点选列表行）不写回仓库 units', (tester) async {
      final pickingTask = _fixtureTask(status: RenewTaskStatus.picking);
      await repo.save(pickingTask);
      await tester.pumpWidget(
          _wrapWithNavigator(task: pickingTask, repo: repo, playback: playback));
      await tester.tap(find.byKey(const Key('open-workbench')));
      await tester.pumpAndSettle();

      // 仍可点选列表行（回看要能浏览）
      await tester.tap(find.byKey(const Key('unit-row-1')));
      await tester.pump();
      expect(find.byType(InspectorPanel), findsOneWidget);

      await tester.tap(find.byKey(const Key('workbench-back-btn')));
      await tester.pumpAndSettle();

      final saved = await repo.findById('wb-1');
      expect(saved!.units, pickingTask.units);
    });
  });

  // 真机缺陷回归：时间线上存在亚像素宽的单元块体时，绘制在 paint() 中途抛出
  // AssertionError，本帧后续所有绘制指令（镜头/抽帧/波形轨，以及 Scaffold 在
  // body 之后才绘制的顶栏与底部栏）全部丢失——控件在树里、布局正确、命中测试
  // 也正常，但屏幕上什么都看不到。这里断言"这一帧没有绘制异常"。
  for (final status in [RenewTaskStatus.awaitingCut, RenewTaskStatus.picking]) {
    testWidgets('存在亚像素宽单元时绘制不抛异常（status=${status.name}）', (tester) async {
      final sliverTask = _fixtureTask(status: status).copyWith(
        units: _unitsWithSliverTail(),
        videoInfo: const VideoInfo(
          width: 1080,
          height: 1920,
          duration: Duration(milliseconds: 92253),
          fps: 30,
          fileSizeBytes: 1000,
        ),
      );
      await repo.save(sliverTask);
      await tester.pumpWidget(
          _wrapWithNavigator(task: sliverTask, repo: repo, playback: playback));
      await tester.tap(find.byKey(const Key('open-workbench')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // 顶栏与底部栏在 Scaffold 里晚于 body 绘制，是最先被"吞掉"的两处
      expect(find.byKey(const Key('workbench-back-btn')), findsOneWidget);
      expect(find.byKey(const Key('workbench-confirm-btn')), findsOneWidget);
    });
  }

  testWidgets('在游标处拆分：播放头不在所选范围内时提示而非静默无操作（Minor）', (tester) async {
    await repo.save(task);
    await tester.pumpWidget(_wrapWithNavigator(task: task, repo: repo, playback: playback));
    await tester.tap(find.byKey(const Key('open-workbench')));
    await tester.pumpAndSettle();

    // 选中单元1（[2000,4000]ms），但播放头仍在初始位置 0（不在该单元范围内）
    await tester.tap(find.byKey(const Key('unit-row-1')));
    await tester.pump();

    // 检查器面板内容在窄栏 + 小测试视口下可能需要滚动才可见
    await tester.ensureVisible(find.byKey(const Key('inspector-split-btn')));
    await tester.tap(find.byKey(const Key('inspector-split-btn')));
    await tester.pump(); // SnackBar 入场动画的第一帧
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.textContaining('播放头不在所选范围内'), findsOneWidget);
  });
}
