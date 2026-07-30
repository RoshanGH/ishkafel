import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'app/app.dart';
import 'core/ai/ai_credentials.dart';
import 'core/ai/ark_chat_client.dart';
import 'core/ai/volcano_asr_provider.dart';
import 'core/ai/volcano_semantic_splitter.dart';
import 'core/analysis/analysis_pipeline.dart';
import 'core/analysis/audio_extractor.dart';
import 'core/analysis/boundary_snapper.dart';
import 'core/analysis/scene_detector.dart';
import 'core/analysis/segmentation_builder.dart';
import 'core/analysis/silence_detector.dart';
import 'core/ffmpeg/ffprobe_service.dart';
import 'core/ffmpeg/thumbnail_service.dart';
import 'core/log/app_log.dart';
import 'core/storage/file_task_repository.dart';
import 'features/import_flow/import_service.dart';
import 'features/tasks/task_list_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final supportDir = await getApplicationSupportDirectory();
  final dataDir = Directory(p.join(supportDir.path, 'ishkafel_data'));
  final repository = FileTaskRepository(dataDir);
  final importService = ImportService(
    repository: repository,
    ffprobe: FfprobeService(),
    thumbnails: ThumbnailService(),
    coversDir: Directory(p.join(dataDir.path, 'covers')),
  );

  final credentials = CredentialsLoader.load(
      devSecretsDir: Directory('${Directory.current.path}/.secrets'));
  final analysisPipeline = _buildAnalysisPipeline(credentials, dataDir);

  runApp(ProviderScope(
    overrides: [
      taskRepositoryProvider.overrideWithValue(repository),
      importServiceProvider.overrideWithValue(importService),
      analysisPipelineProvider.overrideWithValue(analysisPipeline),
    ],
    child: const IshkafelApp(),
  ));
}

/// 凭据完整时组装真实分析管线；不完整时返回 null（导入后跳过自动分析）
/// 打标器暂不配置——标签组选择 UI 属 M3
AnalysisPipeline? _buildAnalysisPipeline(
    AiCredentials credentials, Directory dataDir) {
  if (!credentials.isComplete) {
    AppLog.warn('AI 凭据不完整，跳过自动分析装配（导入后需手动触发）');
    return null;
  }
  return AnalysisPipeline(
    audio: AudioExtractor(),
    silence: const SilenceDetector(),
    scenes: SceneDetector(),
    asr: VolcanoAsrProvider(
      appId: credentials.speechAppId,
      accessToken: credentials.speechAccessToken,
    ),
    splitter: VolcanoSemanticSplitter(
      chat: ArkChatClient(apiKey: credentials.arkApiKey),
    ),
    builder: const SegmentationBuilder(snapper: BoundarySnapper()),
    repository: FileTaskRepository(dataDir),
    workDir: Directory(p.join(dataDir.path, 'analysis_work')),
  );
}
