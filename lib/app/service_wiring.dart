import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/ai/ai_credentials.dart';
import '../core/ai/ark_chat_client.dart';
import '../core/ai/frame_check.dart';
import '../core/ai/volcano_asr_provider.dart';
import '../core/ai/volcano_semantic_splitter.dart';
import '../core/analysis/analysis_pipeline.dart';
import '../core/analysis/batch_frame_extractor.dart';
import '../core/analysis/boundary_reviewer.dart';
import '../core/analysis/boundary_snapper.dart';
import '../core/analysis/frame_signal_extractor.dart';
import '../core/analysis/scene_detector.dart';
import '../core/analysis/segmentation_builder.dart';
import '../core/analysis/shot_boundary_finder.dart';
import '../core/analysis/silence_detector.dart';
import '../core/ffmpeg/thumbnail_service.dart';
import '../core/ai/taggers.dart';
import '../core/analysis/audio_extractor.dart';
import '../core/audio/vocal_separator.dart';
import '../core/log/app_log.dart';
import '../core/miaoa/miaoa_tag_service.dart';
import '../core/script/line_tagger.dart';
import '../core/script/script_transcriber.dart';
import '../core/storage/file_task_repository.dart';
import '../core/analysis/tag_vocabulary.dart';

/// 分析流水线的装配。
///
/// **GUI 与 CLI 共用同一份**：两边各装一套的话，迟早会出现「app 里分析出来
/// 是这样、命令行跑出来是那样」——而那种差异极难查。放在这里而不是
/// `main.dart` 里，就是为了让 `bin/ishkafel.dart` 也够得着。
/// 编导台「从视频提取脚本」的装配：抽音频 → ASR，一句一行。
/// 只依赖语音凭据；不全时返回 null，界面把入口禁用并说明原因（不静默）。
ScriptTranscriber? buildScriptTranscriber(
    AiCredentials credentials, Directory dataDir) {
  if (credentials.speechAppId.isEmpty ||
      credentials.speechAccessToken.isEmpty) {
    return null;
  }
  return ScriptTranscriber(
    audio: AudioExtractor(),
    asr: VolcanoAsrProvider(
      appId: credentials.speechAppId,
      accessToken: credentials.speechAccessToken,
    ),
    scenes: SceneDetector(),
    workDir: Directory(p.join(dataDir.path, 'analysis_work')),
  );
}

/// 编导台「自动打标」的装配：U 层打标员 + miaoa 词表。
/// 方舟凭据缺失时返回 null，界面禁用并说明原因
LineTagger? buildLineTagger(AiCredentials credentials) {
  if (credentials.arkApiKey.isEmpty) return null;
  return LineTagger(
    tagger: UnitTagger(chat: ArkChatClient(apiKey: credentials.arkApiKey)),
    vocabulary: MiaoaTagVocabularySource(MiaoaTagService()),
  );
}

/// 素材画面自查（烧字 + 产品露出品牌）。方舟凭据缺失时返回 null——那时
/// 已选素材标成「未检查」，绝不冒充「画面没问题」。
FrameChecker? buildFrameChecker(AiCredentials credentials) {
  if (credentials.arkApiKey.isEmpty) return null;
  return ArkFrameChecker(ArkChatClient(apiKey: credentials.arkApiKey));
}

AnalysisPipeline? buildAnalysisPipeline(
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
        MiaoaTagService()),
  );
}
