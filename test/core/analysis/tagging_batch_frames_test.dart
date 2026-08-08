import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/tag_dimension.dart';
import 'package:ishkafel/core/ai/taggers.dart';
import 'package:ishkafel/core/analysis/batch_frame_extractor.dart';
import 'package:ishkafel/core/analysis/tag_vocabulary.dart';
import 'package:ishkafel/core/analysis/tagging_service.dart';
import 'package:ishkafel/core/ffmpeg/thumbnail_service.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/models/tag_group_ref.dart';
import 'package:ishkafel/core/models/video_info.dart';
import 'package:path/path.dart' as p;

class _Shots implements ShotTagger {
  var calls = 0;
  @override
  Future<ShotUnderstanding> understand({
    required List<List<int>> frames,
    required List<TagDimension> dimensions,
    String? constraint,
  }) async {
    calls++;
    return const ShotUnderstanding(tags: ['甲'], description: '一个镜头');
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Vocab implements TagVocabularySource {
  @override
  Future<List<String>> vocabularyOf(int groupId) async => const ['甲'];
}

/// 每 [shotCount] 个 1 秒镜头塞进一个单元
List<SemanticUnit> _units(int shotCount) => [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: shotCount * 1000,
        transcript: '台词',
        shots: [
          for (var i = 0; i < shotCount; i++)
            Shot(startMs: i * 1000, endMs: (i + 1) * 1000),
        ],
      ),
    ];

/// 片长默认取实测那条素材的 96 秒——批量划不划算跟片长强相关，
/// 随手写个数字会让这些测试测的是另一回事
RenewTask _task(int shotCount, {int durationMs = 96233}) => RenewTask(
      id: 'T1',
      name: 'a',
      sourcePath: '/v/a.mp4',
      status: RenewTaskStatus.ready,
      createdAt: DateTime.utc(2026, 8, 6),
      updatedAt: DateTime.utc(2026, 8, 6),
      shotTagGroups: const [TagGroupRef(id: 1, name: '镜头组')],
      units: _units(shotCount),
      videoInfo: VideoInfo(
          width: 1080,
          height: 1920,
          duration: Duration(milliseconds: durationMs),
          fps: 30,
          fileSizeBytes: 1),
    );

void main() {
  late Directory temp;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('ishkafel_tagbatch_');
  });
  tearDown(() => temp.deleteSync(recursive: true));

  /// 逐帧抽：记下调用次数，并真的写一个文件出来
  ({ThumbnailService service, List<String> calls}) perFrame() {
    final calls = <String>[];
    return (
      service: ThumbnailService(run: (binary, args) async {
        final out = args.last;
        calls.add(out);
        File(out).writeAsStringSync('one');
        return ProcessResult(1, 0, '', '');
      }),
      calls: calls
    );
  }

  test('镜头够多时一次抽完，之后不再逐帧抽', () async {
    final each = perFrame();
    var batchRuns = 0;
    final shots = _Shots();
    // 40 个镜头 × 3 帧 = 120 帧：96 秒片子上批量 9.1s、逐帧 12.9s
    final task = _task(40);

    final service = TaggingService(
      shotTagger: shots,
      thumbnails: each.service,
      vocabulary: _Vocab(),
      workDir: temp,
      batchFrames: BatchFrameExtractor(run: (binary, args) async {
        batchRuns++;
        final pattern = args.last;
        // select 里有几个 eq 就吐几张
        final n = RegExp(r'eq\(n').allMatches(args.join(' ')).length;
        Directory(p.dirname(pattern)).createSync(recursive: true);
        for (var i = 1; i <= n; i++) {
          File(pattern.replaceAll('%03d', i.toString().padLeft(3, '0')))
              .writeAsStringSync('batch');
        }
        return ProcessResult(1, 0, '', '');
      }),
    );

    await service.tag(task, task.units!);

    expect(batchRuns, 1, reason: '批量的意义就在于只跑一次');
    expect(each.calls, isEmpty, reason: '批量成功后再逐帧抽等于白抽两遍');
    expect(shots.calls, 40, reason: '每个镜头照样各打一次标');
  });

  test('只重打几个镜头时不走批量——为几帧解码整条片子是亏的', () async {
    final each = perFrame();
    var batchRuns = 0;

    final service = TaggingService(
      shotTagger: _Shots(),
      thumbnails: each.service,
      vocabulary: _Vocab(),
      workDir: temp,
      batchFrames: BatchFrameExtractor(run: (binary, args) async {
        batchRuns++;
        return ProcessResult(1, 0, '', '');
      }),
    );

    // 整条片子还是 96 秒，只是这一轮只要重打两个镜头——为 6 帧解码整条片子
    final small = _task(2);
    await service.tag(small, small.units!);

    expect(batchRuns, 0);
    expect(each.calls, hasLength(6), reason: '2 个镜头 × 3 帧');
  });

  test('批量对不上时整批作废，逐帧兜住，标签照样打全', () async {
    final each = perFrame();
    final shots = _Shots();

    final service = TaggingService(
      shotTagger: shots,
      thumbnails: each.service,
      vocabulary: _Vocab(),
      workDir: temp,
      // 只吐 2 张，远少于计划——必须整批作废
      batchFrames: BatchFrameExtractor(run: (binary, args) async {
        final pattern = args.last;
        Directory(p.dirname(pattern)).createSync(recursive: true);
        for (var i = 1; i <= 2; i++) {
          File(pattern.replaceAll('%03d', i.toString().padLeft(3, '0')))
              .writeAsStringSync('batch');
        }
        return ProcessResult(1, 0, '', '');
      }),
    );

    final big = _task(40);
    final result = await service.tag(big, big.units!);

    expect(each.calls, hasLength(120), reason: '40 个镜头 × 3 帧全部退回逐帧');
    expect(shots.calls, 40);
    expect(result.first.shots.every((s) => s.tags.isNotEmpty), isTrue,
        reason: '兜底的意义是结果一样，只是慢一点');
  });

  test('没装批量抽帧也照常工作——它只是快一点，不是前提', () async {
    final each = perFrame();

    final service = TaggingService(
      shotTagger: _Shots(),
      thumbnails: each.service,
      vocabulary: _Vocab(),
      workDir: temp,
    );

    final big = _task(40);
    await service.tag(big, big.units!);

    expect(each.calls, hasLength(120));
  });
}
