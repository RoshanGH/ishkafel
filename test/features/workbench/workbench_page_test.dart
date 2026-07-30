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
}
