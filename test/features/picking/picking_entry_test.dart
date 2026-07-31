import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/models/video_info.dart';
import 'package:ishkafel/core/playback/playback_controller.dart';
import 'package:ishkafel/core/storage/task_repository.dart';
import 'package:ishkafel/features/picking/picking_page.dart';
import 'package:ishkafel/features/tasks/task_list_controller.dart';
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

RenewTask _task(RenewTaskStatus status) => RenewTask(
      id: 'wb-1',
      name: '滴露_植源喷雾',
      sourcePath: '/videos/wb-1.mp4',
      status: status,
      createdAt: DateTime.utc(2026, 7, 30),
      updatedAt: DateTime.utc(2026, 7, 30),
      units: const [
        SemanticUnit(
          index: 0,
          startMs: 0,
          endMs: 4000,
          transcript: '第一句台词',
          shots: [Shot(startMs: 0, endMs: 4000)],
        ),
      ],
      videoInfo: const VideoInfo(
        width: 1080,
        height: 1920,
        duration: Duration(milliseconds: 4000),
        fps: 30,
        fileSizeBytes: 1000,
      ),
    );

Widget _wrap(RenewTask task, TaskRepository repo, FakePlaybackController pb) =>
    ProviderScope(
      overrides: [taskRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
        home: WorkbenchPage(
          task: task,
          playbackFactory: () => pb,
          mediaBuilder: null,
        ),
      ),
    );

void main() {
  testWidgets('已确认切分的任务：底部主按钮是「进入替换选材」，点击进入阶段②', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final repo = _Repo();
    final task = _task(RenewTaskStatus.picking);
    await repo.save(task);
    await tester.pumpWidget(_wrap(task, repo, FakePlaybackController()));
    await tester.pump();

    expect(find.text('进入替换选材'), findsOneWidget,
        reason: '只读回看时不能只留一个灰着的「已确认」，用户会不知道下一步在哪');

    await tester.tap(find.byKey(const Key('workbench-confirm-btn')));
    await tester.pumpAndSettle();
    expect(find.byType(PickingPage), findsOneWidget);
  });
}
