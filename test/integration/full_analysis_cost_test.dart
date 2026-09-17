// 完整分析一条真实素材，并统计火山方舟的 token 用量与费用。
//
//   flutter test test/integration/full_analysis_cost_test.dart \
//     --tags integration --run-skipped
//
// 用用户指定的标签组：台词层「植源分子库」，视觉层「植源场景 / 植源镜头类别
// / 植源动作 / 植源外壳」四个组合并。
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/ai_credentials.dart';
import 'package:ishkafel/core/ai/ark_chat_client.dart';
import 'package:ishkafel/core/ai/taggers.dart';
import 'package:ishkafel/core/ai/volcano_asr_provider.dart';
import 'package:ishkafel/core/ai/volcano_semantic_splitter.dart';
import 'package:ishkafel/core/analysis/analysis_pipeline.dart';
import 'package:ishkafel/core/storage/task_log.dart';
import 'package:ishkafel/core/analysis/audio_extractor.dart';
import 'package:ishkafel/core/analysis/boundary_reviewer.dart';
import 'package:ishkafel/core/analysis/boundary_snapper.dart';
import 'package:ishkafel/core/analysis/frame_signal_extractor.dart';
import 'package:ishkafel/core/analysis/scene_detector.dart';
import 'package:ishkafel/core/analysis/segmentation_builder.dart';
import 'package:ishkafel/core/analysis/shot_boundary_finder.dart';
import 'package:ishkafel/core/analysis/silence_detector.dart';
import 'package:ishkafel/core/analysis/tag_vocabulary.dart';
import 'package:ishkafel/core/ffmpeg/ffprobe_service.dart';
import 'package:ishkafel/core/ffmpeg/thumbnail_service.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/tag_group_ref.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

const _video = '/Users/menggang/Documents/滴露视频/'
    'JC_滴露_植源喷雾_XCT_SQ1&YY6_CH_千川直播_M66028501_0427.mp4';

/// 用户指定的标签组
const _unitGroups = [TagGroupRef(id: 1261, name: '植源分子库')];
const _shotGroups = [
  TagGroupRef(id: 978, name: '植源场景'),
  TagGroupRef(id: 977, name: '植源镜头类别'),
  TagGroupRef(id: 976, name: '植源动作'),
  TagGroupRef(id: 975, name: '植源外壳'),
];

/// doubao-seed-2-0-lite 官网价（元 / 百万 token）。价格会变，这里只用于
/// 给出量级；真实账单以火山控制台为准。
const _pricePerMillionInput = 0.15;
const _pricePerMillionOutput = 1.50;

void main() {
  final creds = CredentialsLoader.load(secretsDirs: [Directory('.secrets')]);
  final skip = !creds.isComplete
      ? '凭据不完整'
      : !File(_video).existsSync()
          ? '测试视频不存在'
          : null;

  test('完整分析一条 96 秒素材，统计 token 与费用', () async {
    final dir = Directory.systemTemp.createTempSync('cost_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final work = Directory('${dir.path}/work')..createSync();

    final info = await FfprobeService().probe(_video);
    final chat = ArkChatClient(apiKey: creds.arkApiKey);
    ArkChatClient.usage.reset();

    final task = RenewTask(
      id: 'cost',
      name: '成本测算',
      sourcePath: _video,
      videoInfo: info,
      status: RenewTaskStatus.analyzing,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      unitTagGroups: _unitGroups,
      shotTagGroups: _shotGroups,
    );

    final pipeline = AnalysisPipeline(
      audio: AudioExtractor(),
      silence: const SilenceDetector(),
      scenes: SceneDetector(),
      shotBoundaries: ShotBoundaryFinder(
        extractor: FrameSignalExtractor(workDir: work),
        reviewer: BoundaryReviewer(chat: chat, workDir: work),
      ),
      asr: VolcanoAsrProvider(
          appId: creds.speechAppId, accessToken: creds.speechAccessToken),
      splitter: VolcanoSemanticSplitter(chat: chat),
      builder: const SegmentationBuilder(snapper: BoundarySnapper()),
      repository: FileTaskRepository(dir),
      workDir: work,
      thumbnails: ThumbnailService(),
      unitTagger: UnitTagger(chat: chat),
      shotTagger: ShotTagger(chat: chat),
      vocabulary:
          MiaoaTagVocabularySource(MiaoaTagService()),
    );

    final sw = Stopwatch()..start();
    final result = await pipeline.analyze(task, by: ActorKind.agent, actor: 'Agent', onProgress: (p) {
      // ignore: avoid_print
      if (p.done == null || p.done! % 10 == 0) print('  ${p.summary}');
    });
    sw.stop();

    final units = result.units!;
    final shots = units.fold<int>(0, (n, u) => n + u.shots.length);
    final u = ArkChatClient.usage;
    final cost = u.promptTokens / 1e6 * _pricePerMillionInput +
        u.completionTokens / 1e6 * _pricePerMillionOutput;

    final tagged = units
        .expand((x) => x.shots)
        .where((s) => s.tags.isNotEmpty)
        .length;
    final described = units
        .expand((x) => x.shots)
        .where((s) => s.description != null)
        .length;

    // ignore: avoid_print
    print('''

===== 一条 ${(info.duration.inMilliseconds / 1000).toStringAsFixed(1)}s 素材的完整分析 =====
台词语义单元   ${units.length} 个（打上标签的 ${units.where((x) => x.tags.isNotEmpty).length} 个）
视觉镜头       $shots 个（打上标签 $tagged 个 · 有画面描述 $described 个）
耗时           ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s
方舟用量       $u
估算费用       ¥${cost.toStringAsFixed(4)}
  （输入 ${u.promptTokens} × ¥$_pricePerMillionInput/M
    输出 ${u.completionTokens} × ¥$_pricePerMillionOutput/M；单价以控制台为准）

样例：''');
    for (final unit in units.take(2)) {
      // ignore: avoid_print
      print('  U${unit.index + 1} 标签${unit.tags} 「${unit.transcript}」');
      for (final s in unit.shots.take(3)) {
        // ignore: avoid_print
        print('     ${s.startMs}~${s.endMs}ms ${s.tags} — ${s.description}');
      }
    }

    expect(units, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 30)), skip: skip);
}
