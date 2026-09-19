import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/ark_chat_client.dart';
import 'package:ishkafel/core/ai/tag_dimension.dart';
import 'package:ishkafel/core/ai/taggers.dart';
import 'package:ishkafel/core/analysis/analysis_pipeline.dart';
import 'package:ishkafel/core/storage/task_log.dart';
import 'package:ishkafel/core/analysis/analysis_progress.dart';
import 'package:ishkafel/core/analysis/audio_extractor.dart';
import 'package:ishkafel/core/analysis/boundary_snapper.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/analysis/scene_detector.dart';
import 'package:ishkafel/core/analysis/segmentation_builder.dart';
import 'package:ishkafel/core/analysis/silence_detector.dart';
import 'package:ishkafel/core/analysis/tag_vocabulary.dart';
import 'package:ishkafel/core/ffmpeg/thumbnail_service.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/tag_group_ref.dart';
import 'package:ishkafel/core/models/video_info.dart';
import 'package:ishkafel/core/net/json_poster.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

class _Asr implements AsrProvider {
  @override
  Future<List<AsrSentence>> transcribe(String pcmPath) async => const [
        AsrSentence(startMs: 0, endMs: 4100, text: '第一句'),
        AsrSentence(startMs: 4100, endMs: 9200, text: '第二句'),
      ];
}

class _Splitter implements SemanticSplitter {
  @override
  Future<List<UnitDraft>> split(List<AsrSentence> sentences) async => [
        for (final s in sentences)
          UnitDraft(startMs: s.startMs, endMs: s.endMs, transcript: s.text),
      ];
}

class _Vocabulary implements TagVocabularySource {
  @override
  Future<List<String>> vocabularyOf(int groupId) async => const ['甲', '乙'];
}

/// 打标器是具体类而非接口，只能继承后覆写 tag；构造要的 ArkChatClient
/// 给一个永不真正发请求的替身
ArkChatClient _stubChat() => ArkChatClient(
    apiKey: 'x',
    post: (_, _, _) async => const JsonPostResult(statusCode: 200, body: '{}'));

class _UnitTagger extends UnitTagger {
  _UnitTagger() : super(chat: _stubChat());
  @override
  Future<ShotUnderstanding> understand(
          {required String transcript,
          required List<TagDimension> dimensions,
          String? constraint}) async =>
      const ShotUnderstanding(tags: ['甲']);
}

class _ShotTagger extends ShotTagger {
  _ShotTagger() : super(chat: _stubChat());
  @override
  Future<ShotUnderstanding> understand(
          {required List<List<int>> frames,
          required List<TagDimension> dimensions,
          String? constraint}) async =>
      const ShotUnderstanding(tags: ['乙']);
}

const _showinfo =
    '[Parsed_showinfo_1 @ 0x60] n: 0 pts: 120 pts_time:4.0 fmt:yuv420p\n';

late Directory _temp;

AnalysisPipeline _pipeline(
  FileTaskRepository repo, {
  bool tagging = false,
}) =>
    AnalysisPipeline(
      audio: AudioExtractor(run: (_, args) async {
        await File(args.last).writeAsBytes(Uint8List(16000));
        return ProcessResult(1, 0, '', '');
      }),
      silence: const SilenceDetector(),
      scenes:
          SceneDetector(run: (_, _) async => ProcessResult(1, 0, '', _showinfo)),
      asr: _Asr(),
      splitter: _Splitter(),
      builder: const SegmentationBuilder(snapper: BoundarySnapper()),
      repository: repo,
      workDir: Directory('${_temp.path}/work'),
      clock: () => DateTime.utc(2026, 7, 31),
      unitTagger: tagging ? _UnitTagger() : null,
      shotTagger: tagging ? _ShotTagger() : null,
      thumbnails: tagging
          ? ThumbnailService(run: (_, args) async {
              await File(args.last).writeAsBytes(Uint8List.fromList([1, 2, 3]));
              return ProcessResult(1, 0, '', '');
            })
          : null,
      vocabulary: tagging ? _Vocabulary() : null,
    );

RenewTask _task({bool withTagGroups = false}) => RenewTask(
      id: 't1',
      name: '测试片',
      sourcePath: '/v/a.mp4',
      videoInfo: const VideoInfo(
          width: 1080,
          height: 1920,
          duration: Duration(milliseconds: 9200),
          fps: 30,
          fileSizeBytes: 1),
      status: RenewTaskStatus.analyzing,
      createdAt: DateTime.utc(2026, 7, 31),
      updatedAt: DateTime.utc(2026, 7, 31),
      unitTagGroups: withTagGroups ? [const TagGroupRef(id: 1, name: '语义类型')] : const [],
      shotTagGroups: withTagGroups ? [const TagGroupRef(id: 2, name: '画面类型')] : const [],
    );

void main() {
  setUp(() async {
    _temp = await Directory.systemTemp.createTemp('pipeline_progress_');
  });

  tearDown(() async => _temp.delete(recursive: true));

  group('分析过程要能被看见（一条 75 秒素材实测跑了十几分钟）', () {
    test('每个阶段开始时都上报一次', () async {
      final repo = FileTaskRepository(_temp);
      await repo.save(_task());
      final seen = <AnalysisStage>[];

      await _pipeline(repo).analyze(_task(),
          by: ActorKind.agent,
          actor: 'Agent',
          onProgress: (p) => seen.add(p.stage));

      for (final stage in [
        AnalysisStage.extractingAudio,
        AnalysisStage.detectingScenes,
        AnalysisStage.transcribing,
        AnalysisStage.splitting,
        AnalysisStage.building,
      ]) {
        expect(seen, contains(stage), reason: '$stage 没有上报，界面会静默停住');
      }
    });

    test('阶段按执行顺序上报，不倒退', () async {
      final repo = FileTaskRepository(_temp);
      await repo.save(_task());
      final seen = <AnalysisStage>[];

      await _pipeline(repo).analyze(_task(),
          by: ActorKind.agent,
          actor: 'Agent',
          onProgress: (p) => seen.add(p.stage));

      final indices = seen.map((s) => s.index).toList();
      for (var i = 1; i < indices.length; i++) {
        expect(indices[i], greaterThanOrEqualTo(indices[i - 1]),
            reason: '进度回退会让用户以为出错重来了：${seen.map((s) => s.name).toList()}');
      }
    });

    test('不打标时不上报打标阶段——不能显示一个永远走不到的步骤', () async {
      final repo = FileTaskRepository(_temp);
      await repo.save(_task());
      final seen = <AnalysisStage>[];

      await _pipeline(repo).analyze(_task(),
          by: ActorKind.agent,
          actor: 'Agent',
          onProgress: (p) => seen.add(p.stage));

      expect(seen, isNot(contains(AnalysisStage.taggingShots)));
      expect(seen, isNot(contains(AnalysisStage.taggingUnits)));
    });

    test('没有传回调时照常分析（回调是可选的）', () async {
      final repo = FileTaskRepository(_temp);
      await repo.save(_task());

      final result = await _pipeline(repo).analyze(_task(),
          by: ActorKind.agent, actor: 'Agent');

      expect(result.status, RenewTaskStatus.ready);
    });
  });

  group('打标阶段的逐项进度（最慢的一段，必须有计数）', () {
    test('视觉镜头打标逐个上报「已完成 / 共」', () async {
      final repo = FileTaskRepository(_temp);
      final task = _task(withTagGroups: true);
      await repo.save(task);
      final shotReports = <AnalysisProgress>[];

      await _pipeline(repo, tagging: true).analyze(task,
          by: ActorKind.agent, actor: 'Agent', onProgress: (p) {
        if (p.stage == AnalysisStage.taggingShots) shotReports.add(p);
      });

      expect(shotReports, isNotEmpty);
      final total = shotReports.first.total;
      expect(total, isNotNull, reason: '没有总数就只能显示一个不确定态转圈');
      expect(shotReports.last.done, total,
          reason: '结束时必须走到满格，否则进度条永远停在 n-1');
    });

    test('已完成数单调不减（并发回填时最容易搞反）', () async {
      final repo = FileTaskRepository(_temp);
      final task = _task(withTagGroups: true);
      await repo.save(task);
      final done = <int>[];

      await _pipeline(repo, tagging: true).analyze(task,
          by: ActorKind.agent, actor: 'Agent', onProgress: (p) {
        if (p.stage == AnalysisStage.taggingShots && p.done != null) {
          done.add(p.done!);
        }
      });

      for (var i = 1; i < done.length; i++) {
        expect(done[i], greaterThanOrEqualTo(done[i - 1]),
            reason: '并发打标时按完成顺序累加，数字不能跳回去：$done');
      }
    });

    test('单元打标也带计数', () async {
      final repo = FileTaskRepository(_temp);
      final task = _task(withTagGroups: true);
      await repo.save(task);
      final unitReports = <AnalysisProgress>[];

      await _pipeline(repo, tagging: true).analyze(task,
          by: ActorKind.agent, actor: 'Agent', onProgress: (p) {
        if (p.stage == AnalysisStage.taggingUnits) unitReports.add(p);
      });

      expect(unitReports.last.done, unitReports.last.total);
      expect(unitReports.last.total, 2, reason: '这条素材切出 2 个单元');
    });
  });

  group('回调本身出错不能拖垮分析', () {
    test('回调抛异常时分析照常完成', () async {
      final repo = FileTaskRepository(_temp);
      await repo.save(_task());

      final result = await _pipeline(repo).analyze(_task(),
          by: ActorKind.agent, actor: 'Agent', onProgress: (_) {
        throw StateError('界面已销毁');
      });

      expect(result.status, RenewTaskStatus.ready,
          reason: '进度只是「说一声」；因为没人听就把整条分析废掉，'
              '等于让十几分钟的计算白跑');
    });
  });
}
