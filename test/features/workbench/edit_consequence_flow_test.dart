import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/tag_dimension.dart';
import 'package:ishkafel/core/ai/taggers.dart';
import 'package:ishkafel/core/analysis/audio_extractor.dart';
import 'package:ishkafel/core/analysis/tag_vocabulary.dart';
import 'package:ishkafel/core/analysis/tagging_service.dart';
import 'package:ishkafel/core/ffmpeg/thumbnail_service.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart';
import 'package:ishkafel/core/models/tag_group_ref.dart';
import 'package:ishkafel/core/models/video_info.dart';
import 'package:ishkafel/core/playback/playback_controller.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/core/storage/task_repository.dart';
import 'package:ishkafel/features/tasks/task_list_controller.dart';
import 'package:ishkafel/features/workbench/timeline_media_builder.dart';
import 'package:ishkafel/features/tasks/new_task_wizard/wizard_providers.dart';
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

/// 两个已打标的单元，U1 还挑好了替换素材
RenewTask _task() => RenewTask(
      id: 'ec-1',
      name: '滴露_植源喷雾',
      sourcePath: '/videos/ec-1.mp4',
      status: RenewTaskStatus.editing,
      createdAt: DateTime.utc(2026, 8, 3),
      updatedAt: DateTime.utc(2026, 8, 3),
      unitTagGroups: const [TagGroupRef(id: 1, name: '台词标签组')],
      units: const [
        SemanticUnit(
          index: 0,
          startMs: 0,
          endMs: 10000,
          transcript: '第一句台词',
          tags: ['促销'],
          shots: [Shot(startMs: 0, endMs: 10000, tags: ['近景'])],
        ),
        SemanticUnit(
          index: 1,
          startMs: 10000,
          endMs: 20000,
          transcript: '第二句台词',
          tags: ['卖点'],
          shots: [Shot(startMs: 10000, endMs: 20000, tags: ['中景'])],
        ),
      ],
      replacements: [
        UnitReplacement.whole(const [101, 102]),
        UnitReplacement.keepOriginal(),
      ],
      videoInfo: const VideoInfo(
        width: 1080,
        height: 1920,
        duration: Duration(milliseconds: 20000),
        fps: 30,
        fileSizeBytes: 1000,
      ),
    );

/// 只记录「谁被送去打标了」的假打标器
class _RecordingUnitTagger implements UnitTagger {
  final asked = <String>[];
  @override
  Future<ShotUnderstanding> understand({
    required String transcript,
    required List<TagDimension> dimensions,
    String? constraint,
  }) async {
    asked.add(transcript);
    return const ShotUnderstanding(tags: ['重打出来的'], rawReply: '{}');
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTagService implements MiaoaTagService {
  @override
  Future<List<TagGroup>> listGroups() async => const [
        TagGroup(
            id: 7,
            name: '植源分子库',
            materialType: 'storyboard',
            tagType: 'public',
            tags: ['近景', '中景']),
      ];

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Vocab implements TagVocabularySource {
  @override
  Future<List<String>> vocabularyOf(int groupId) async => ['重打出来的'];
}

Future<_Repo> _open(WidgetTester tester, {TaggingService? tagging}) async {
  final repo = _Repo();
  final task = _task();
  await repo.save(task);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      taskRepositoryProvider.overrideWithValue(repo),
      taggingServiceProvider.overrideWithValue(tagging),
      miaoaTagServiceProvider.overrideWithValue(_FakeTagService()),
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
  return repo;
}

/// 把 U1 的结束边界往回拖若干帧（每点一次步进按钮 = 1 帧 ≈ 33ms）
Future<void> _shrinkFirstUnit(WidgetTester tester, {required int frames}) async {
  await tester.tap(find.byKey(const Key('unit-row-0')));
  await tester.pump();
  for (var i = 0; i < frames; i++) {
    await tester.tap(find.byKey(const Key('inspector-end-minus')));
    await tester.pump();
  }
}

/// 等「手停下来」的 3 秒窗口
Future<void> _settleConsequence(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 4));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('改动很小时也会问，但两项都默认不勾', (tester) async {
    await _open(tester);

    await _shrinkFirstUnit(tester, frames: 1);
    await _settleConsequence(tester);

    expect(find.byKey(const Key('consequence-confirm')), findsOneWidget);
    final boxes = tester.widgetList<Checkbox>(find.byType(Checkbox)).toList();
    expect(boxes.every((c) => c.value == false), isTrue,
        reason: '只挪了一帧，默认勾上会让用户白白重挑一遍素材');
  });

  testWidgets('大改动默认勾上；确认后清掉这个单元挑好的素材并落库', (tester) async {
    final repo = await _open(tester);

    // 10 秒的单元砍掉 30 帧（约 1 秒，10%），超过「改得多」的阈值
    await _shrinkFirstUnit(tester, frames: 30);
    await _settleConsequence(tester);

    final boxes = tester.widgetList<Checkbox>(find.byType(Checkbox)).toList();
    expect(boxes.every((c) => c.value == true), isTrue);

    await tester.tap(find.byKey(const Key('consequence-confirm')));
    await tester.pumpAndSettle();

    final saved = await repo.findById('ec-1');
    expect(saved!.replacements![0].mode, ReplacementMode.keepOriginal,
        reason: '用户点了「清除」，就必须真的清掉并落库');
    expect(saved.units![0].tagsStale, isTrue,
        reason: '标签标记为过期，而不是抹掉——重打是异步的');
    expect(saved.units![0].tags, ['促销'],
        reason: '标记过期不等于把标签删了');
  });

  testWidgets('点「都不用」：素材与标签原样保留', (tester) async {
    final repo = await _open(tester);

    await _shrinkFirstUnit(tester, frames: 30);
    await _settleConsequence(tester);

    await tester.tap(find.byKey(const Key('consequence-skip')));
    await tester.pumpAndSettle();

    final saved = await repo.findById('ec-1');
    expect(saved!.replacements![0].wholeCandidateIds, [101, 102]);
    expect(saved.units![0].tagsStale, isFalse);
  });

  testWidgets('点了「重新打标」就真的送去打标，且只打改到的那几个单元', (tester) async {
    final tagger = _RecordingUnitTagger();
    final repo = await _open(tester,
        tagging: TaggingService(
          unitTagger: tagger,
          vocabulary: _Vocab(),
          workDir: Directory.systemTemp.createTempSync('ishkafel_retag_'),
        ));

    await _shrinkFirstUnit(tester, frames: 30);
    await _settleConsequence(tester);
    await tester.tap(find.byKey(const Key('consequence-confirm')));
    await tester.pumpAndSettle();

    // 拖 U1 的结束边界同时改了 U2 的开始（无缝覆盖），两个单元的画面都变了
    expect(tagger.asked, ['第一句台词', '第二句台词']);

    final saved = await repo.findById('ec-1');
    expect(saved!.units![0].tags, ['重打出来的']);
    expect(saved.units![0].tagsStale, isFalse,
        reason: '打完要把「待重打」标记清掉，否则界面上一直挂着「已过期」');
  });

  testWidgets('没配 AI 服务时如实说明，而不是假装打过了', (tester) async {
    final repo = await _open(tester);

    await _shrinkFirstUnit(tester, frames: 30);
    await _settleConsequence(tester);
    await tester.tap(find.byKey(const Key('consequence-confirm')));
    await tester.pumpAndSettle();

    expect(find.textContaining('尚未配置 AI 服务'), findsOneWidget);
    final saved = await repo.findById('ec-1');
    expect(saved!.units![0].tagsStale, isTrue,
        reason: '打不成就得让标记留着，用户才知道这份标签还没更新');
  });

  group('标签组设置', () {
    testWidgets('改完标签组勾着「立即重打」，就用新词表把全片重打一遍',
        (tester) async {
      final tagger = _RecordingUnitTagger();
      final repo = await _open(tester,
          tagging: TaggingService(
            unitTagger: tagger,
            vocabulary: _Vocab(),
            workDir: Directory.systemTemp.createTempSync('ishkafel_rt_'),
          ));

      await tester.tap(find.byKey(const Key('workbench-tag-groups-btn')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('task-tag-groups-save')));
      await tester.pumpAndSettle();

      expect(tagger.asked, ['第一句台词', '第二句台词'],
          reason: '换词表等于把整份标签作废了，只重打其中几个没有意义');
      final saved = await repo.findById('ec-1');
      expect(saved!.units!.every((u) => u.tags.contains('重打出来的')), isTrue);
    });

    testWidgets('不勾「立即重打」就只存标签组，不去打标', (tester) async {
      final tagger = _RecordingUnitTagger();
      await _open(tester,
          tagging: TaggingService(
            unitTagger: tagger,
            vocabulary: _Vocab(),
            workDir: Directory.systemTemp.createTempSync('ishkafel_rt2_'),
          ));

      await tester.tap(find.byKey(const Key('workbench-tag-groups-btn')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('task-tag-groups-retag')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('task-tag-groups-save')));
      await tester.pumpAndSettle();

      expect(tagger.asked, isEmpty);
    });

    testWidgets('取消不改任何东西', (tester) async {
      final repo = await _open(tester);

      await tester.tap(find.byKey(const Key('workbench-tag-groups-btn')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('task-tag-groups-cancel')));
      await tester.pumpAndSettle();

      final saved = await repo.findById('ec-1');
      expect(saved!.unitTagGroups.map((g) => g.id), [1]);
    });
  });

  testWidgets('问过一次之后不翻旧账：没有新改动就不再弹', (tester) async {
    await _open(tester);

    await _shrinkFirstUnit(tester, frames: 30);
    await _settleConsequence(tester);
    await tester.tap(find.byKey(const Key('consequence-skip')));
    await tester.pumpAndSettle();

    // 只切换选中，不做任何编辑
    await tester.tap(find.byKey(const Key('unit-row-1')));
    await tester.pump();
    await _settleConsequence(tester);

    expect(find.byKey(const Key('consequence-confirm')), findsNothing,
        reason: '每改一次都被翻一遍旧账，用户会开始无脑点「都不用」');
  });
}
