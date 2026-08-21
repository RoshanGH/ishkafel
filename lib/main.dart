import 'dart:io';

import 'package:flutter/material.dart';

import 'core/audio/material_vocal_cache.dart';
import 'features/workbench/preview_tracks.dart';
import 'core/audio/vocal_separator.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'app/app.dart';
import 'core/ai/ai_credentials.dart';
import 'core/audio/bgm_cache_factory.dart';
import 'core/ffmpeg/ffprobe_service.dart';
import 'core/ffmpeg/process_runner.dart';
import 'core/ffmpeg/thumbnail_service.dart';
import 'app/flutter_error_bridge.dart';
import 'app/service_wiring.dart';
import 'features/director/director_providers.dart';
import 'cli/commands/open_command.dart';
import 'core/log/app_log.dart';
import 'core/miaoa/miaoa_account_service.dart';
import 'core/diagnostics/tool_installer.dart';
import 'core/miaoa/miaoa_auth_service.dart';
import 'core/diagnostics/environment_report.dart';
import 'core/storage/cache_usage.dart';
import 'core/storage/task_artifacts.dart';
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
import 'core/miaoa/material_downloader.dart';
import 'core/export/export_runner.dart';
import 'core/miaoa/miaoa_content_service.dart';

/// 素材人声分离器。预览与导出共用一份缓存目录，同一条素材只分离一次
MaterialVocalCache materialVocals(Directory dataDir) => MaterialVocalCache(
      separator: VocalSeparator(
        binary: resolveVocalSeparatorBinary(),
        modelDir: Directory(p.join(dataDir.path, 'separator_models')),
      ),
      cacheDir: Directory(p.join(dataDir.path, 'material_vocals')),
    );

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // 尽早接管：框架异常默认经 debugPrint 输出，真机直接跑二进制时不可见
  installFlutterErrorForwarding();
  MediaKit.ensureInitialized();
  final supportDir = await getApplicationSupportDirectory();
  final dataDir = Directory(p.join(supportDir.path, 'ishkafel_data'));
  final repository = FileTaskRepository(dataDir);
  final coversDir = Directory(p.join(dataDir.path, 'covers'));
  final artifactCleaner =
      FileTaskArtifactCleaner(dataDir: dataDir);
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
  final analysisPipeline = buildAnalysisPipeline(credentials, dataDir);

  // 启动期预检 ffmpeg/ffprobe：GUI 进程 PATH 不含 Homebrew 目录，
  // 缺失时列表页常驻横幅引导安装，而不是等用户导入时撞见子进程异常
  final mediaTools = sharedMediaToolsLocator.preflight();

  // 开机扫一遍孤儿产物。删任务时清干净只解决一半问题——崩溃、手动删存档、
  // 开发期换机器总会留下没主的东西，它们只会一直躺在盘上占地方
  await _sweepOrphans(repository, dataDir);

  // `ishkafel open <task>` 会带 --task=<id> 把 app 拉起来。CLI 写、GUI 读，
  // 两边对同一个约定（见 open_command.dart）
  final initialTaskId = initialTaskIdFrom(args);

  runApp(ProviderScope(
    overrides: [
      initialTaskIdProvider.overrideWithValue(initialTaskId),
      taskRepositoryProvider.overrideWithValue(repository),
      importServiceProvider.overrideWithValue(importService),
      analysisPipelineProvider.overrideWithValue(analysisPipeline),
      // 编导台「从视频提取脚本」：凭据齐了才给实例，否则入口禁用并说明
      scriptTranscriberProvider
          .overrideWithValue(buildScriptTranscriber(credentials, dataDir)),
      // 编导台「生成配音」：同上，语音凭据齐了才有
      lineVoiceFactoryProvider
          .overrideWithValue(defaultLineVoiceFactory(credentials, dataDir)),
      // 编导台「自动打标」：方舟凭据齐了才有
      lineTaggerProvider.overrideWithValue(buildLineTagger(credentials)),
      // 参考视觉镜头打标（多帧 vision：标签 + 画面描述）
      refShotTaggerProvider
          .overrideWithValue(buildRefShotTagger(credentials)),
      mediaToolsStatusProvider.overrideWithValue(mediaTools),
      taskArtifactCleanerProvider.overrideWithValue(artifactCleaner),
      // 设置页：扫描/体检都用真实目录与真实进程，注入点集中在这里
      cacheScannerProvider.overrideWithValue(
          CacheScanner(dataDir: dataDir)),
      environmentProbeProvider.overrideWithValue(defaultEnvironmentProbe(
          mediaTools: mediaTools, credentials: credentials)),
      miaoaAccountServiceProvider.overrideWithValue(MiaoaAccountService()),
      miaoaAuthServiceProvider.overrideWithValue(MiaoaAuthService()),
      toolInstallerProvider.overrideWithValue(ToolInstaller()),
      dataDirProvider.overrideWithValue(dataDir),
      // 「生成配音」：凭据齐了才给工厂，否则工作台把按钮禁用并说明原因，
      // 而不是让用户点了之后撞一个网络错误
      voiceSwapFactoryProvider.overrideWithValue(defaultVoiceSwapFactory(
          credentials: credentials, dataDir: dataDir)),
      // 矩阵导出：真实 ffmpeg + 真实下载。素材缓存按任务分目录，
      // 清理缓存时能整目录带走
      // 预览音轨：与导出共用同一个混音器，听到的就是要交付的
      // 选中配乐就把它下到本地：和预览/导出读同一份缓存
      bgmFetcherProvider.overrideWithValue(bgmCache(dataDir).fetch),
      // 挑素材时就把本体下到本地：和导出读同一个缓存目录，导出时不必再下
      materialFetcherProvider.overrideWithValue(MaterialDownloader(
        content: MiaoaContentService(),
        cacheDir: Directory(p.join(dataDir.path, 'material_cache')),
      ).fetch),
      // 预览与导出共用同一份素材人声：听到的就是要交付的
      // （工具没装时 vocalsOf 一律返回 null，界面据此如实说明）
      materialSeparatorProvider
          .overrideWithValue(materialVocals(dataDir).vocalsOf),
      exportRunnerFactoryProvider.overrideWithValue((taskId) => ExportRunner(
            run: const ResolvingProcessRunner().call,
            workDir: Directory(p.join(dataDir.path, 'export_work', taskId)),
            resolveBgm: bgmCache(dataDir).fetch,
            // 整体替换的段落铺了配乐时，用素材的纯人声——否则素材自带的
            // 背景音和新配乐两首曲子一起响
            separateMaterial: materialVocals(dataDir).vocalsOf,
            // 镜头替换要按候选的真实时长算变速倍率
            probeDurationMs: (path) async => (await FfprobeService(
                    run: const ResolvingProcessRunner().call)
                .probe(path))
                .duration
                .inMilliseconds,
            fetchMaterial: MaterialDownloader(
              content: MiaoaContentService(),
              cacheDir: Directory(p.join(dataDir.path, 'material_cache')),
            ).fetch,
          )),
    ],
    child: const IshkafelApp(),
  ));
}

/// 清掉归属不到任何现存任务的产物。
///
/// 失败不阻断启动：读不出任务清单时**一个都不删**——宁可留着占地方，
/// 也不能因为清单是空的就把用户所有素材当孤儿清了。
Future<void> _sweepOrphans(FileTaskRepository repository, Directory dataDir) async {
  try {
    final tasks = await repository.findAll();
    final artifacts = TaskArtifacts(dataDir);
    // 无主的 + 用完即弃的。后者归属得到现存任务，只靠孤儿判定永远清不掉
    final junk = [
      ...artifacts.orphans({for (final t in tasks) t.id}),
      ...artifacts.transients(),
    ];
    if (junk.isEmpty) return;
    final freed = artifacts.delete(junk);
    AppLog.info('启动清理：${junk.length} 项无用产物，释放 ${formatBytes(freed)}');
  } catch (e) {
    AppLog.warn('启动清理孤儿产物失败，跳过：$e');
  }
}

/// 凭据完整时组装真实分析管线；不完整时返回 null（导入后跳过自动分析）。
///
/// 两层打标在这里接通：taggers 走同一个 Ark 客户端（无状态，可共享），
/// 受控词表走 [MiaoaTagVocabularySource]——按**任务自己选的**标签组现取，