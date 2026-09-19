// 用**当前**算法重新分析磁盘上已有的任务，并把前后差异打出来。
//
// 运行方式：
//   flutter test test/integration/reanalyze_existing_tasks_test.dart \
//     --tags integration --run-skipped
//
// 为什么要有这个：算法改了之后，已经分析过的任务不会自动跟着变。测试阶段
// 需要拿真实素材看新算法的实际影响（尤其是台词语义单元与视觉镜头各自变了
// 多少），而走界面「重新分析」既慢又依赖窗口焦点。
//
// **会覆盖任务数据**：重新分析的结果直接落库，原有切分（以及基于它的编辑）
// 被替换。跑之前会把原文件备份到 <数据目录>/tasks_backup_<时间戳>/。
@Tags(['integration'])
library;

import 'dart:convert';
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
import 'package:ishkafel/core/ffmpeg/thumbnail_service.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

/// macOS 上应用的数据目录（与 main.dart 的 getApplicationSupportDirectory 同址）
final _dataDir = Directory('${Platform.environment['HOME']}/Library/'
    'Application Support/com.jichuang.ishkafel/ishkafel_data');

({int units, int shots}) _shape(RenewTask t) {
  final us = t.units ?? const [];
  return (units: us.length, shots: us.fold(0, (n, u) => n + u.shots.length));
}

void main() {
  final creds = CredentialsLoader.load(secretsDirs: [Directory('.secrets')]);
  final skipReason = !creds.isComplete
      ? '真实凭据不完整（.secrets）'
      : !_dataDir.existsSync()
          ? '数据目录不存在：${_dataDir.path}'
          : null;

  test('用当前算法重新分析已有任务，并打印前后对比', () async {
    final workDir = Directory('${_dataDir.path}/analysis_work');
    final repo = FileTaskRepository(_dataDir);
    final before = await repo.findAll();
    if (before.isEmpty) {
      markTestSkipped('数据目录里没有任务');
      return;
    }

    // 覆盖前先备份：重新分析会替换切分结构，出问题要能还原
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final backup = Directory('${_dataDir.path}/tasks_backup_$stamp')
      ..createSync(recursive: true);
    for (final f in Directory('${_dataDir.path}/tasks').listSync()) {
      if (f is File) f.copySync('${backup.path}/${f.uri.pathSegments.last}');
    }
    // ignore: avoid_print
    print('原任务已备份到 ${backup.path}');

    final chat = ArkChatClient(apiKey: creds.arkApiKey);
    final pipeline = AnalysisPipeline(
      audio: AudioExtractor(),
      silence: const SilenceDetector(),
      scenes: SceneDetector(),
      shotBoundaries: ShotBoundaryFinder(
        extractor: FrameSignalExtractor(workDir: workDir),
        reviewer: BoundaryReviewer(chat: chat, workDir: workDir),
      ),
      asr: VolcanoAsrProvider(
          appId: creds.speechAppId, accessToken: creds.speechAccessToken),
      splitter: VolcanoSemanticSplitter(chat: chat),
      builder: const SegmentationBuilder(snapper: BoundarySnapper()),
      repository: repo,
      workDir: workDir,
      thumbnails: ThumbnailService(),
      unitTagger: UnitTagger(chat: chat),
      shotTagger: ShotTagger(chat: chat),
      vocabulary:
          MiaoaTagVocabularySource(MiaoaTagService()),
    );

    final report = <String>[];
    for (final task in before) {
      final sourcePath = task.sourcePath;
      if (sourcePath == null) {
        report.add('${task.name}：空白任务，没有原片可分析，跳过');
        continue;
      }
      if (!File(sourcePath).existsSync()) {
        report.add('${task.name}：源文件不存在，跳过');
        continue;
      }
      final was = _shape(task);
      final sw = Stopwatch()..start();
      final after = await pipeline.analyze(task,
          by: ActorKind.agent, actor: 'Agent', onProgress: (p) {
        // ignore: avoid_print
        if (p.done == null || p.done! % 10 == 0) print('  ${p.summary}');
      });
      sw.stop();
      final now = _shape(after);
      report.add('${task.name}\n'
          '   台词语义单元 ${was.units} → ${now.units}\n'
          '   视觉镜头     ${was.shots} → ${now.shots}\n'
          '   耗时 ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s');
      expect(after.units, isNotNull);
      expect(after.units!, isNotEmpty);
    }

    // ignore: avoid_print
    print('\n===== 重新分析结果 =====\n${report.join('\n')}');
    // 供人工核对的完整切分（写到备份目录旁边，不污染数据目录本身）
    File('${backup.path}/after.json').writeAsStringSync(const JsonEncoder
            .withIndent('  ')
        .convert([for (final t in await repo.findAll()) t.toJson()]));
  },
      timeout: const Timeout(Duration(minutes: 30)),
      skip: skipReason);
}
