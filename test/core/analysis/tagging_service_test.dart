import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/tag_dimension.dart';
import 'package:ishkafel/core/ai/taggers.dart';
import 'package:ishkafel/core/analysis/tag_vocabulary.dart';
import 'package:ishkafel/core/analysis/tagging_service.dart';
import 'package:ishkafel/core/ffmpeg/thumbnail_service.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/models/tag_group_ref.dart';
import 'package:ishkafel/core/models/video_info.dart';

class _FakeUnitTagger implements UnitTagger {
  final asked = <String>[];
  @override
  Future<ShotUnderstanding> understand({
    required String transcript,
    required List<TagDimension> dimensions,
  }) async {
    asked.add(transcript);
    return ShotUnderstanding(tags: ['新单元标签'], rawReply: '{}');
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeShotTagger implements ShotTagger {
  var calls = 0;
  @override
  Future<ShotUnderstanding> understand({
    required List<List<int>> frames,
    required List<TagDimension> dimensions,
  }) async {
    calls++;
    return ShotUnderstanding(
        tags: ['新镜头标签'], description: '新画面描述', rawReply: '{}');
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeVocabulary implements TagVocabularySource {
  @override
  Future<List<String>> vocabularyOf(int groupId) async => ['甲', '乙'];
}

RenewTask _task() => RenewTask(
      id: 'tg-1',
      name: '任务',
      sourcePath: '/videos/tg-1.mp4',
      status: RenewTaskStatus.editing,
      createdAt: DateTime.utc(2026, 8, 3),
      updatedAt: DateTime.utc(2026, 8, 3),
      unitTagGroups: const [TagGroupRef(id: 1, name: '台词标签组')],
      shotTagGroups: const [TagGroupRef(id: 2, name: '镜头标签组')],
      videoInfo: const VideoInfo(
        width: 1080,
        height: 1920,
        duration: Duration(milliseconds: 30000),
        fps: 30,
        fileSizeBytes: 1,
      ),
    );

List<SemanticUnit> _units() => const [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 10000,
        transcript: 'U1 台词',
        tags: ['旧标签1'],
        shots: [Shot(startMs: 0, endMs: 10000, tags: ['旧镜头1'])],
      ),
      SemanticUnit(
        index: 1,
        startMs: 10000,
        endMs: 20000,
        transcript: 'U2 台词',
        tags: ['旧标签2'],
        tagsStale: true,
        shots: [Shot(startMs: 10000, endMs: 20000, tags: ['旧镜头2'])],
      ),
      SemanticUnit(
        index: 2,
        startMs: 20000,
        endMs: 30000,
        transcript: 'U3 台词',
        tags: ['旧标签3'],
        shots: [Shot(startMs: 20000, endMs: 30000, tags: ['旧镜头3'])],
      ),
    ];

({TaggingService service, _FakeUnitTagger unit, _FakeShotTagger shot})
    _build() {
  final unit = _FakeUnitTagger();
  final shot = _FakeShotTagger();
  final dir = Directory.systemTemp.createTempSync('ishkafel_tag_');
  addTearDown(() => dir.deleteSync(recursive: true));
  return (
    service: TaggingService(
      unitTagger: unit,
      shotTagger: shot,
      thumbnails: ThumbnailService(run: (_, args) async {
        await File(args.last).writeAsBytes(List<int>.filled(64, 1));
        return ProcessResult(1, 0, '', '');
      }),
      vocabulary: _FakeVocabulary(),
      workDir: dir,
      clock: () => DateTime.utc(2026, 8, 3),
    ),
    unit: unit,
    shot: shot,
  );
}

void main() {
  test('不传 only 时全打', () async {
    final b = _build();

    final out = await b.service.tag(_task(), _units());

    expect(b.unit.asked, ['U1 台词', 'U2 台词', 'U3 台词']);
    expect(b.shot.calls, 3);
    expect(out.every((u) => u.tags.contains('新单元标签')), isTrue);
  });

  test('only 限定只打那几个单元，其余原样保留', () async {
    final b = _build();

    final out = await b.service.tag(_task(), _units(), only: {1});

    expect(b.unit.asked, ['U2 台词'],
        reason: '用户只改了 U2，把全片十几个单元重打一遍既慢又费钱');
    expect(b.shot.calls, 1);

    expect(out[1].tags, ['新单元标签']);
    expect(out[1].shots.first.tags, ['新镜头标签']);
    expect(out[0].tags, ['旧标签1'], reason: '没要求重打的单元一个字都不该动');
    expect(out[0].shots.first.tags, ['旧镜头1']);
    expect(out[2].tags, ['旧标签3']);
    expect(out[2].shots.first.tags, ['旧镜头3']);
  });

  test('打完把「待重打」标记清掉，两层都清', () async {
    final b = _build();

    final out = await b.service.tag(_task(), _units(), only: {1});

    expect(out[1].tagsStale, isFalse,
        reason: '标记还留着的话，界面上会一直挂着「标签已过期」');
    expect(out[1].shots.every((s) => !s.tagsStale), isTrue);
  });
}
