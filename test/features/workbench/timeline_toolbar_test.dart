import 'dart:io';

import 'package:flutter/material.dart';
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
import 'package:ishkafel/features/workbench/timeline_media_builder.dart';
import 'package:ishkafel/features/workbench/workbench_page.dart';

class _Repo implements TaskRepository {
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

RenewTask _task() => RenewTask(
      id: 't1',
      name: '测试成片',
      sourcePath: '/tmp/x.mp4',
      videoInfo: const VideoInfo(
        width: 1080,
        height: 1920,
        duration: Duration(milliseconds: 8000),
        fps: 30,
        fileSizeBytes: 1,
      ),
      status: RenewTaskStatus.awaitingCut,
      createdAt: DateTime(2026, 7, 31),
      updatedAt: DateTime(2026, 7, 31),
      units: const [
        SemanticUnit(
          index: 0,
          startMs: 0,
          endMs: 4000,
          transcript: '第一句台词',
          shots: [Shot(startMs: 0, endMs: 4000)],
        ),
        SemanticUnit(
          index: 1,
          startMs: 4000,
          endMs: 8000,
          transcript: '第二句台词',
          shots: [Shot(startMs: 4000, endMs: 8000)],
        ),
      ],
    );

void main() {
  testWidgets('时间线工具条提供拆分与合并入口（此前只能从右侧检查器触发）',
      (tester) async {
    final repo = _Repo();
    await repo.save(_task());
    final playback = FakePlaybackController();

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

    expect(find.byKey(const Key('timeline-split-btn')), findsOneWidget,
        reason: '拆分是本页最高频的操作之一，工具条上应有直接入口');
    expect(find.byKey(const Key('timeline-merge-btn')), findsOneWidget);
  });

  testWidgets('未选中任何对象时拆分/合并禁用，而不是点了没反应', (tester) async {
    final repo = _Repo();
    await repo.save(_task());

    await tester.pumpWidget(ProviderScope(
      overrides: [taskRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
        home: WorkbenchPage(
          task: _task(),
          playbackFactory: FakePlaybackController.new,
          mediaBuilder: _fakeMediaBuilder(),
        ),
      ),
    ));
    await tester.pump();

    final split = tester
        .widget<IconButton>(find.byKey(const Key('timeline-split-btn')));
    final merge = tester
        .widget<IconButton>(find.byKey(const Key('timeline-merge-btn')));
    expect(split.onPressed, isNull,
        reason: '没有选中对象时这两个操作无从执行，应禁用并给出可见的禁用态');
    expect(merge.onPressed, isNull);
  });

  testWidgets('工具条禁用态随编辑器状态更新（页面级 setState 移除后的回归防线）',
      (tester) async {
    final repo = _Repo();
    await repo.save(_task());
    final playback = FakePlaybackController();

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

    IconButton undoBtn() =>
        tester.widget<IconButton>(find.byKey(const Key('timeline-undo-btn')));
    expect(undoBtn().onPressed, isNull, reason: '尚无编辑，撤销应禁用');

    // 从左栏选中一个单元再拆分，制造一次真实编辑
    await tester.tap(find.byKey(const Key('unit-row-0')));
    await tester.pump();
    playback.seekMs(2000);
    await tester.pump();
    await tester.tap(find.byKey(const Key('timeline-split-btn')));
    await tester.pump();

    expect(undoBtn().onPressed, isNotNull,
        reason: '产生了一次编辑，撤销必须变为可用；工具条若不自己监听编辑器，'
            '会一直停在禁用态（页面级 setState 已因性能原因移除）');
  });
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
