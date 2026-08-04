import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/audio_extractor.dart';
import 'package:ishkafel/core/audio/voice_plan.dart';
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

RenewTask _task({VoicePlan voices = VoicePlan.empty}) => RenewTask(
      id: 'v-1',
      name: '滴露',
      sourcePath: '/v/a.mp4',
      status: RenewTaskStatus.editing,
      createdAt: DateTime.utc(2026, 8, 4),
      updatedAt: DateTime.utc(2026, 8, 4),
      voices: voices,
      units: const [
        SemanticUnit(
            index: 0, startMs: 0, endMs: 2000, transcript: '第一句',
            shots: [Shot(startMs: 0, endMs: 2000)]),
        SemanticUnit(
            index: 1, startMs: 2000, endMs: 4000, transcript: '第二句',
            shots: [Shot(startMs: 2000, endMs: 4000)]),
      ],
      videoInfo: const VideoInfo(
        width: 1080, height: 1920,
        duration: Duration(milliseconds: 4000), fps: 30, fileSizeBytes: 1),
    );

Future<_Repo> _open(WidgetTester tester,
    {VoicePlan voices = VoicePlan.empty}) async {
  final repo = _Repo();
  final task = _task(voices: voices);
  await repo.save(task);
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(ProviderScope(
    overrides: [taskRepositoryProvider.overrideWithValue(repo)],
    child: MaterialApp(
      home: WorkbenchPage(
        task: task,
        playbackFactory: FakePlaybackController.new,
        mediaBuilder: _fakeMediaBuilder(),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  testWidgets('选中一个单元 → 换音色 → 落库', (tester) async {
    final repo = await _open(tester);

    await tester.tap(find.byKey(const Key('unit-row-0')));
    await tester.pumpAndSettle();
    expect(find.text('保持原片配音'), findsOneWidget,
        reason: '没换的时候要写出来，留空用户分不清是没换还是功能没生效');

    await tester.tap(find.byKey(const Key('inspector-change-voice')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('voice-unit-1')));
    await tester.pump();
    await tester.tap(
        find.byKey(const Key('voice-option-zh_female_vv_uranus_bigtts')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('voice-confirm')));
    await tester.pumpAndSettle();

    final saved = await repo.findById('v-1');
    expect(saved!.voices.assignedUnits, [0, 1],
        reason: '面板里勾了两句，就该两句都换');
    expect(saved.voices.voiceOf(0)!.name, 'vivi 2.0');
    expect(find.text('vivi 2.0'), findsWidgets, reason: '检查器上要立刻反映出来');
  });

  testWidgets('改回原声后卡片写回「保持原片配音」', (tester) async {
    const vivi = VoiceRef(id: 'zh_female_vv_uranus_bigtts', name: 'vivi 2.0');
    final repo = await _open(tester, voices: VoicePlan.empty.assign([0], vivi));

    await tester.tap(find.byKey(const Key('unit-row-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('inspector-change-voice')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('voice-revert')));
    await tester.pumpAndSettle();

    final saved = await repo.findById('v-1');
    expect(saved!.voices.voiceOf(0), isNull);
    expect(find.text('保持原片配音'), findsOneWidget);
  });
}
