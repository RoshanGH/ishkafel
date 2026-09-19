import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/models/video_info.dart';
import 'package:ishkafel/core/playback/playback_controller.dart';
import 'package:ishkafel/core/storage/task_log.dart';
import 'package:ishkafel/core/storage/task_repository.dart';
import 'package:ishkafel/features/settings/settings_providers.dart';
import 'package:ishkafel/features/tasks/task_list_controller.dart';
import 'package:ishkafel/features/workbench/timeline_media_builder.dart';
import 'package:ishkafel/features/workbench/workbench_page.dart';
import 'package:ishkafel/core/analysis/audio_extractor.dart';
import 'package:ishkafel/core/ffmpeg/thumbnail_service.dart';

/// **人没编辑过，这一页就一个字都不许往盘上写。**
///
/// 2026-09-18 真机抓到的那一笔（正式包、工作台开着 #6）：
///
/// ```
/// #8  19:04:18  Agent  unit.tags   tags：[] → [痛点]
/// #9  19:04:19  人     units.edit  changed：[…tags:[促单,痛点]] → [… tags:[促单]]
/// ```
///
/// 中间隔 1.35 秒（防抖 800ms + 落盘），人一根手指都没动——**Agent 上一笔
/// 写进去的标签被这一页手上那份进门时的旧快照原样盖了回去**。
///
/// 触发链：Agent 写盘时会写在场状态 → 这一页跟着它把选中挪过去 →
/// `select()` 会 `notifyListeners` → `_onEditorChanged` → 自动保存。
/// 而那道「真的变了才写」的守卫里 `_savedUnits` 还是 null（这一次会话里
/// 还没保存过），于是拦不住：整份旧 units 照写。
void main() {
  final logDir = Directory.systemTemp.createTempSync('ishkafel_wb_nowrite_');
  tearDownAll(() {
    if (logDir.existsSync()) logDir.deleteSync(recursive: true);
  });

  List<SemanticUnit> units({List<String> tags = const []}) => [
        SemanticUnit(
          uid: 'kaaaaaaaaaaa',
          index: 0,
          startMs: 0,
          endMs: 2000,
          transcript: '第一句台词',
          tags: tags,
          shots: const [Shot(startMs: 0, endMs: 2000)],
        ),
        const SemanticUnit(
          uid: 'kbbbbbbbbbbb',
          index: 1,
          startMs: 2000,
          endMs: 4000,
          transcript: '第二句台词',
          shots: [Shot(startMs: 2000, endMs: 4000)],
        ),
      ];

  RenewTask taskWith(List<SemanticUnit> u) => RenewTask(
        id: 'wb-1',
        name: '滴露',
        sourcePath: '/videos/wb-1.mp4',
        status: RenewTaskStatus.ready,
        createdAt: DateTime.utc(2026, 9, 18),
        updatedAt: DateTime.utc(2026, 9, 18),
        units: u,
        videoInfo: const VideoInfo(
          width: 1080,
          height: 1920,
          duration: Duration(milliseconds: 4000),
          fps: 30,
          fileSizeBytes: 1000,
        ),
      );

  testWidgets('Agent 写完、人只是点了一下某个单元：不写盘、不记账、不回滚',
      (tester) async {
    final repo = _Repo();
    final task = taskWith(units());
    await repo.save(task);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        taskRepositoryProvider.overrideWithValue(repo),
        dataDirProvider.overrideWithValue(logDir),
      ],
      child: MaterialApp(
        home: WorkbenchPage(
          task: task,
          playbackFactory: FakePlaybackController.new,
          mediaBuilder: _fakeMediaBuilder(),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Agent 这期间写了盘：给第一个单元打上标签
    await repo.save(taskWith(units(tags: const ['痛点'])));

    // 人（或跟随 Agent 的界面）只是把选中挪到第二个单元——纯选中
    await tester.tap(find.byKey(const Key('unit-row-1')));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect((await repo.findById('wb-1'))!.units!.first.tags, ['痛点'],
        reason: '这一页拿着进门那一刻的旧快照，照写就把 Agent 刚写的标签盖没了');
    expect(
        TaskLogFile(dataDir: logDir, taskId: 'wb-1').read(limit: 1 << 20),
        isEmpty,
        reason: '人一根手指都没动，日志里不许出现一笔他名下的改动');
  });
}

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

TimelineMediaBuilder _fakeMediaBuilder() {
  final thumbnails = ThumbnailService(run: (_, args) async {
    await File(args.last).writeAsBytes(List<int>.filled(600, 1));
    return ProcessResult(1, 0, '', '');
  });
  final audio = AudioExtractor(run: (_, args) async {
    await File(args.last).writeAsBytes(List<int>.filled(64, 0));
    return ProcessResult(1, 0, '', '');
  });
  return TimelineMediaBuilder(thumbnails: thumbnails, audio: audio);
}
