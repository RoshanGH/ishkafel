import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
import 'package:ishkafel/features/workbench/timeline/timeline_view.dart';
import 'package:ishkafel/features/workbench/timeline_media_builder.dart';
import 'package:ishkafel/features/workbench/unit_list_panel.dart';
import 'package:ishkafel/features/workbench/workbench_page.dart';

class _InMemoryRepo implements TaskRepository {
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

TimelineMediaBuilder _fakeMediaBuilder() => TimelineMediaBuilder(
      thumbnails: ThumbnailService(run: (_, args) async {
        await File(args.last).writeAsBytes(List<int>.filled(600, 1));
        return ProcessResult(1, 0, '', '');
      }),
      audio: AudioExtractor(run: (_, args) async {
        await File(args.last).writeAsBytes(List<int>.filled(64, 0));
        return ProcessResult(1, 0, '', '');
      }),
    );

RenewTask _task() => RenewTask(
      id: 't1',
      name: '测试成片',
      sourcePath: '/tmp/x.mp4',
      videoInfo: const VideoInfo(
          width: 1080,
          height: 1920,
          duration: Duration(milliseconds: 4000),
          fps: 30,
          fileSizeBytes: 1),
      status: RenewTaskStatus.editing,
      createdAt: DateTime(2026, 7, 31),
      updatedAt: DateTime(2026, 7, 31),
      units: [
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
      ],
    );

void main() {
  group('播放位置更新的重建范围（性能：播放时每秒 30 次 tick）', () {
    late _InMemoryRepo repo;
    late FakePlaybackController playback;

    setUp(() {
      repo = _InMemoryRepo();
      playback = FakePlaybackController();
    });

    Future<void> pumpPage(WidgetTester tester) async {
      await repo.save(_task());
      await tester.pumpWidget(ProviderScope(
        overrides: [taskRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
          home: WorkbenchPage(
            task: _task(),
            playbackFactory: () => playback,
            mediaBuilder: _fakeMediaBuilder(),
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('位置变化不重建左栏单元列表与右栏检查器', (tester) async {
      await pumpPage(tester);

      final listBefore = tester.widget<UnitListPanel>(find.byType(UnitListPanel));
      final inspectorBefore =
          tester.widget<InspectorPanel>(find.byType(InspectorPanel));

      // 模拟播放推进：真机上这个事件每秒来 30 次
      for (final ms in [100, 200, 300, 400, 500]) {
        playback.seekMs(ms);
        await tester.pump();
      }

      final listAfter = tester.widget<UnitListPanel>(find.byType(UnitListPanel));
      final inspectorAfter =
          tester.widget<InspectorPanel>(find.byType(InspectorPanel));

      expect(identical(listBefore, listAfter), isTrue,
          reason: '播放位置只驱动时间线上那条播放头线；重建左栏说明用了页面级 setState，'
              '真机实测每 tick 因此付出 10~12ms（60fps 预算的 70%）');
      expect(identical(inspectorBefore, inspectorAfter), isTrue,
          reason: '同上：检查器与播放位置无关，不应被位置流拖着重建');
    });

    testWidgets('位置变化仍然传达到时间线（重建范围收窄不能把功能一起收掉）',
        (tester) async {
      await pumpPage(tester);

      playback.seekMs(1234);
      await tester.pump();

      final timeline = tester.widget<TimelineView>(find.byType(TimelineView));
      expect(timeline.playhead.value, 1234,
          reason: '时间线必须仍能拿到最新播放位置，否则播放头不会动');
    });

    testWidgets('时间线绘制被 RepaintBoundary 隔离，播放头移动不牵动整窗重光栅',
        (tester) async {
      await pumpPage(tester);

      // 不能用 find.ancestor(matching: RepaintBoundary) 断言：Flutter 自己在
      // 每个路由页外面就套了一层（routes.dart 的 _ModalScopeState._page），
      // 于是 MaterialApp 路由内任何 widget 都必然有 RepaintBoundary 祖先——
      // 把实现里那行整个删掉，这种断言照样绿。要验的是**渲染层**：时间线
      // 那个 RenderCustomPaint 的直接父节点就是一个 RenderRepaintBoundary。
      final paintFinder = find.descendant(
        of: find.byType(TimelineView),
        matching: find.byType(CustomPaint),
      );
      expect(paintFinder, findsWidgets, reason: '前提：时间线里有 CustomPaint');
      final renderPaint = tester.renderObject(paintFinder.last);
      expect(renderPaint.parent, isA<RenderRepaintBoundary>(),
          reason: 'CustomPaint 没有紧邻的 RepaintBoundary 时，markNeedsPaint 会'
              '一路上溯到 RenderView，每次播放头移动都要重录整页绘制指令');
    });
  });
}
