import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'app/app.dart';
import 'core/ai/ai_credentials.dart';
import 'core/ai/ark_chat_client.dart';
import 'core/ai/taggers.dart';
import 'core/ai/volcano_asr_provider.dart';
import 'core/ai/volcano_semantic_splitter.dart';
import 'core/analysis/analysis_pipeline.dart';
import 'core/analysis/batch_frame_extractor.dart';
import 'core/audio/bgm_cache.dart';
import 'core/audio/bgm_library.dart';
import 'core/analysis/audio_extractor.dart';
import 'core/analysis/boundary_snapper.dart';
import 'core/analysis/scene_detector.dart';
import 'core/analysis/boundary_reviewer.dart';
import 'core/analysis/frame_signal_extractor.dart';
import 'core/analysis/segmentation_builder.dart';
import 'core/analysis/shot_boundary_finder.dart';
import 'core/analysis/silence_detector.dart';
import 'core/analysis/tag_vocabulary.dart';
import 'core/ffmpeg/ffprobe_service.dart';
import 'core/ffmpeg/process_runner.dart';
import 'core/ffmpeg/thumbnail_service.dart';
import 'core/log/app_log.dart';
import 'core/miaoa/miaoa_account_service.dart';
import 'core/miaoa/miaoa_locator.dart';
import 'core/miaoa/miaoa_tag_service.dart';
import 'core/diagnostics/environment_report.dart';
import 'core/storage/cache_usage.dart';
import 'core/storage/file_task_repository.dart';
import 'features/import_flow/import_service.dart';
import 'features/settings/settings_providers.dart';
import 'features/tasks/environment_banner.dart';
import 'features/tasks/task_artifact_cleaner.dart';
import 'features/tasks/task_list_controller.dart';
import 'features/workbench/voice_swap_runner.dart';
import 'features/export/export_dialog.dart';
import 'features/picking/picking_providers.dart';
import 'features/workbench/bgm_picker_sheet.dart';
import 'features/export/material_downloader.dart';
import 'core/export/export_runner.dart';
import 'core/miaoa/miaoa_content_service.dart';
import 'core/audio/vocal_separator.dart';
import 'core/audio/audio_track_builder.dart';
import 'features/workbench/preview_audio.dart';
import 'features/workbench/preview_composer.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 尽早接管：框架异常默认经 debugPrint 输出，真机直接跑二进制时不可见
  AppLog.installFlutterErrorForwarding();
  MediaKit.ensureInitialized();
  final supportDir = await getApplicationSupportDirectory();
  final dataDir = Directory(p.join(supportDir.path, 'ishkafel_data'));
  final repository = FileTaskRepository(dataDir);
  final coversDir = Directory(p.join(dataDir.path, 'covers'));
  final workDir = Directory(p.join(dataDir.path, 'analysis_work'));
  final artifactCleaner =
      FileTaskArtifactCleaner(coversDir: coversDir, workDir: workDir);
  final importService = ImportService(
    repository: repository,
    ffprobe: FfprobeService(),
    thumbnails: ThumbnailService(),
    coversDir: coversDir,
  );

  // 两个位置都找：开发期从项目目录跑 `flutter run` 用前者；双击启动的
  // app 工作目录是 `/`，只能靠后者（打包版更常见的是 --dart-define 注入，
  // 见 scripts/build_macos.sh，那条路径优先级最高）
  final credentials = CredentialsLoader.load(secretsDirs: [
    Directory('${Directory.current.path}/.secrets'),
    Directory('${dataDir.path}/credentials'),
  ]);
  final analysisPipeline = _buildAnalysisPipeline(credentials, dataDir);

  // 启动期预检 ffmpeg/ffprobe：GUI 进程 PATH 不含 Homebrew 目录，
  // 缺失时列表页常驻横幅引导安装，而不是等用户导入时撞见子进程异常
  final mediaTools = sharedMediaToolsLocator.preflight();

  runApp(ProviderScope(
    overrides: [
      taskRepositoryProvider.overrideWithValue(repository),
      importServiceProvider.overrideWithValue(importService),
      analysisPipelineProvider.overrideWithValue(analysisPipeline),
      mediaToolsStatusProvider.overrideWithValue(mediaTools),
      taskArtifactCleanerProvider.overrideWithValue(artifactCleaner),
      // 设置页：扫描/体检都用真实目录与真实进程，注入点集中在这里
      cacheScannerProvider.overrideWithValue(
          CacheScanner(coversDir: coversDir, workDir: workDir)),
      environmentProbeProvider.overrideWithValue(defaultEnvironmentProbe(
          mediaTools: mediaTools, credentials: credentials)),
      miaoaAccountServiceProvider.overrideWithValue(MiaoaAccountService()),
      dataDirProvider.overrideWithValue(dataDir),
      // 「生成配音」：凭据齐了才给工厂，否则工作台把按钮禁用并说明原因，
      // 而不是让用户点了之后撞一个网络错误
      voiceSwapFactoryProvider.overrideWithValue(defaultVoiceSwapFactory(
          credentials: credentials, dataDir: dataDir)),
      // 矩阵导出：真实 ffmpeg + 真实下载。素材缓存按任务分目录，
      // 清理缓存时能整目录带走
      // 预览音轨：与导出共用同一个混音器，听到的就是要交付的
      audioTrackBuilderFactoryProvider
          .overrideWithValue((taskId) => AudioTrackBuilder(
                run: const ResolvingProcessRunner().call,
                workDir:
                    Directory(p.join(dataDir.path, 'preview_audio', taskId)),
                // 配乐走本地缓存：miaoa 的签名地址隔天就 403，直接拿存在任务
                // 里的那个去请求，昨天选好的配乐今天就放不出来
                resolveBgm: bgmCache(dataDir).fetch,
              )),
      // 预览合成：有替换时把画面也拼出来，看到的就是那一条变体
      previewComposerFactoryProvider
          .overrideWithValue((taskId) => PreviewComposer(
                run: const ResolvingProcessRunner().call,
                workDir:
                    Directory(p.join(dataDir.path, 'preview_video', taskId)),
                fetchMaterial: MaterialDownloader(
                  content: MiaoaContentService(binary: resolveMiaoaBinary()),
                  cacheDir: Directory(p.join(dataDir.path, 'material_cache')),
                ).fetch,
                probeDurationMs: (path) async => (await FfprobeService(
                        run: const ResolvingProcessRunner().call)
                    .probe(path))
                    .duration
                    .inMilliseconds,
              )),
      // 选中配乐就把它下到本地：和预览/导出读同一份缓存
      bgmFetcherProvider.overrideWithValue(bgmCache(dataDir).fetch),
      // 挑素材时就把本体下到本地：和导出读同一个缓存目录，导出时不必再下
      materialFetcherProvider.overrideWithValue(MaterialDownloader(
        content: MiaoaContentService(binary: resolveMiaoaBinary()),
        cacheDir: Directory(p.join(dataDir.path, 'material_cache')),
      ).fetch),
      exportRunnerFactoryProvider.overrideWithValue((taskId) => ExportRunner(
            run: const ResolvingProcessRunner().call,
            workDir: Directory(p.join(dataDir.path, 'export_work', taskId)),
            resolveBgm: bgmCache(dataDir).fetch,
            // 镜头替换要按候选的真实时长算变速倍率
            probeDurationMs: (path) async => (await FfprobeService(
                    run: const ResolvingProcessRunner().call)
                .probe(path))
                .duration
                .inMilliseconds,
            fetchMaterial: MaterialDownloader(
              content: MiaoaContentService(binary: resolveMiaoaBinary()),
              cacheDir: Directory(p.join(dataDir.path, 'material_cache')),
            ).fetch,
          )),
    ],
    child: const IshkafelApp(),
  ));
}

/// 凭据完整时组装真实分析管线；不完整时返回 null（导入后跳过自动分析）。
///
/// 两层打标在这里接通：taggers 走同一个 Ark 客户端（无状态，可共享），
/// 受控词表走 [MiaoaTagVocabularySource]——按**任务自己选的**标签组现取，
/// 而不是在这里写死一份全局词表。
/// 配乐缓存：全应用共用一份（同一首曲子被多个任务用到时只下一次）
BgmCache bgmCache(Directory dataDir) => BgmCache(
      library: BgmLibrary(binary: resolveMiaoaBinary()),
      cacheDir: Directory(p.join(dataDir.path, 'bgm_cache')),
      // 缓存里可能躺着上次下崩的半截文件、或者地址失效时返回的错误页——
      // 解不出来就删掉重下，别等到导出时 ffmpeg 报一个看不懂的错。
      //
      // 用 playable 而不是 probe：后者解析的是**视频**信息，纯音频文件会以
      // 「没有视频流」抛错，把好好的配乐判成坏的
      verify: FfprobeService(run: const ResolvingProcessRunner().call).playable,
    );

AnalysisPipeline? _buildAnalysisPipeline(
    AiCredentials credentials, Directory dataDir) {
  if (!credentials.isComplete) {
    AppLog.warn('AI 凭据不完整，跳过自动分析装配（导入后需手动触发）');
    return null;
  }
  final chat = ArkChatClient(apiKey: credentials.arkApiKey);
  return AnalysisPipeline(
    audio: AudioExtractor(),
    // 口播/背景音分离：模型落到数据目录（工具默认放 /tmp，系统一清就要重下
    // 几百兆）。没装分离工具时这一步会失败，分析照常完成，只影响换配乐
    separator: VocalSeparator(
      binary: resolveVocalSeparatorBinary(),
      modelDir: Directory(p.join(dataDir.path, 'separator_models')),
    ),
    silence: const SilenceDetector(),
    scenes: SceneDetector(),
    // 视觉镜头切点：双判据（画面差分 + 颜色直方图）+ 灰区画面复核。
    // 复核用与视觉打标同一个 Ark 客户端，只看拿不准的那些、且有次数上限。
    shotBoundaries: ShotBoundaryFinder(
      extractor: FrameSignalExtractor(
          workDir: Directory(p.join(dataDir.path, 'analysis_work'))),
      reviewer: BoundaryReviewer(
          chat: chat,
          workDir: Directory(p.join(dataDir.path, 'analysis_work'))),
    ),
    asr: VolcanoAsrProvider(
      appId: credentials.speechAppId,
      accessToken: credentials.speechAccessToken,
    ),
    splitter: VolcanoSemanticSplitter(chat: chat),
    builder: const SegmentationBuilder(snapper: BoundarySnapper()),
    repository: FileTaskRepository(dataDir),
    workDir: Directory(p.join(dataDir.path, 'analysis_work')),
    thumbnails: ThumbnailService(),
    batchFrames: BatchFrameExtractor(),
    unitTagger: UnitTagger(chat: chat),
    shotTagger: ShotTagger(chat: chat),
    vocabulary: MiaoaTagVocabularySource(
        MiaoaTagService(binary: resolveMiaoaBinary())),
  );
}
