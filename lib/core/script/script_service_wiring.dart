import 'dart:io';

import 'package:path/path.dart' as p;

import '../ai/ai_credentials.dart';
import '../ai/ark_chat_client.dart';
import '../ai/taggers.dart';
import '../ai/volcano_asr_provider.dart';
import '../audio/tts_client.dart';
import '../ffmpeg/process_runner.dart';
import '../log/app_log.dart';
import '../models/renew_task.dart';
import '../audio/delivery_analyzer.dart';
import 'line_delivery_service.dart';
import 'line_voice_service.dart';
import 'script_doc.dart';

/// 脚本成片这条线的服务装配。
///
/// **GUI 与 CLI 共用这一份**：界面那边靠 riverpod 注入，CLI 是另一个进程、
/// 用不了 riverpod，但装配逻辑必须是同一套——两边不一致的话，Agent 做出来
/// 的东西人一打开就是另一个样子。
typedef LineVoiceFactory = LineVoiceService Function(RenewTask task);

/// 配音服务：TTS 走豆包，产物落 `<dataDir>/voices/<taskId>/`
/// （TaskArtifacts 收编该目录，删任务随目录清走）。
///
/// 词级时间戳由 ASR 对合成音频转写补上——TTS 服务不回词级时间戳，
/// 而字幕断句、按镜头切分全靠它。凭据不全时返回 null，由调用方说清
/// 「该把 key 放哪儿」，不要跑到一半报 401
LineVoiceFactory? defaultLineVoiceFactory(
    AiCredentials credentials, Directory dataDir) {
  if (credentials.speechAppId.isEmpty ||
      credentials.speechAccessToken.isEmpty) {
    return null;
  }
  final asr = VolcanoAsrProvider(
    appId: credentials.speechAppId,
    accessToken: credentials.speechAccessToken,
  );
  return (task) => LineVoiceService(
        tts: TtsClient(
          appId: credentials.speechAppId,
          accessToken: credentials.speechAccessToken,
        ),
        outputDir: Directory(p.join(dataDir.path, 'voices', task.id)),
        measureMs: measureAudioMs,
        transcribeWords: (audio) => transcribeVoiceWords(asr, audio),
      );
}

/// 「参考片这一句怎么念」的分析服务，按任务造（切片与缓存都落在任务目录下）
typedef LineDeliveryFactory = LineDeliveryService Function(RenewTask task);

/// 念法分析：切参考片 → 多模态模型听 → 一句语音指令，结论按内容指纹缓存。
///
/// 缺方舟 key 时返回 null——**调用方必须把这件事说出来**：没有它配音照样
/// 出得来，只是每句都是默认语气，而「情绪扁平」的成片和正常成片肉眼分不出，
/// 静默降级等于把问题埋到用户看片子的那一刻
LineDeliveryFactory? defaultLineDeliveryFactory(
    AiCredentials credentials, Directory dataDir) {
  if (credentials.arkApiKey.isEmpty) return null;
  final analyzer =
      ArkDeliveryAnalyzer(chat: ArkChatClient(apiKey: credentials.arkApiKey));
  return (task) {
    // 切片与结论都放参考片切片目录：TaskArtifacts 已收编 script_refs，
    // 删任务时随目录清走，不留孤儿
    final workDir = Directory(p.join(dataDir.path, 'script_refs', task.id));
    return LineDeliveryService(
      analyzer: analyzer,
      slice: (videoPath, startMs, endMs) =>
          sliceReferenceWav(videoPath, workDir, startMs, endMs),
      cacheDir: workDir,
    );
  };
}

/// 从参考片切出 `[startMs, endMs)` 的 16k 单声道 WAV——多模态模型吃的就是
/// 这个规格。切片是**用完即弃**的中间产物，读完就删，不然一条 20 句的片子
/// 会在盘上留下 20 个没人再读的 wav
Future<List<int>> sliceReferenceWav(
    String videoPath, Directory workDir, int startMs, int endMs) async {
  workDir.createSync(recursive: true);
  final out = File(p.join(workDir.path, 'delivery_slice_${startMs}_$endMs.wav'));
  try {
    final r = await systemProcessRunner('ffmpeg', [
      '-y', '-v', 'quiet',
      '-ss', '${startMs / 1000}', '-to', '${endMs / 1000}',
      '-i', videoPath,
      '-vn', '-ar', '16000', '-ac', '1', out.path,
    ]);
    if (r.exitCode != 0 || !out.existsSync()) {
      throw StateError('从参考片切出这一句失败（$startMs~$endMs ms，'
          'exit=${r.exitCode}）');
    }
    return out.readAsBytesSync();
  } finally {
    try {
      out.deleteSync();
    } catch (_) {}
  }
}

/// mp3 → 16k 单声道 PCM（临时文件，用完即删）→ ASR → 词级时间戳
Future<List<VoiceWord>> transcribeVoiceWords(
    VolcanoAsrProvider asr, File audio) async {
  final pcm = File('${audio.path}.pcm');
  try {
    final r = await systemProcessRunner('ffmpeg', [
      '-y', '-i', audio.path,
      '-vn', '-ac', '1', '-ar', '16000', '-f', 's16le',
      pcm.path,
    ]);
    if (r.exitCode != 0) {
      throw StateError('ffmpeg 转 PCM 失败（exit=${r.exitCode}）');
    }
    final sentences = await asr.transcribe(pcm.path);
    return [
      for (final s in sentences)
        for (final w in s.words)
          VoiceWord(text: w.text, startMs: w.startMs, endMs: w.endMs),
    ];
  } finally {
    try {
      pcm.deleteSync();
    } catch (_) {}
  }
}

/// 用 ffprobe 量音频实际时长——配音时长是行时间轴的根，不能按比特率估
Future<int> measureAudioMs(File audio) async {
  final r = await systemProcessRunner('ffprobe', [
    '-v', 'quiet', '-show_entries', 'format=duration', '-of', 'csv=p=0',
    audio.path,
  ]);
  final seconds = double.tryParse('${r.stdout}'.trim());
  if (seconds == null) {
    AppLog.warn('量不出音频时长（${audio.path}）');
    return 0;
  }
  return (seconds * 1000).round();
}

/// 参考视觉镜头打标（多帧 vision，一次给标签 + 画面描述——与 U 层视觉镜头
/// 打标同一个 ShotTagger）。null = 方舟凭据缺失。
///
/// 摆在 core 而不是编导台的 providers 里：CLI 也要造这个东西，而 CLI 是
/// 纯 Dart 编译，碰不得任何 flutter 包
ShotTagger? buildRefShotTagger(AiCredentials credentials) {
  if (credentials.arkApiKey.isEmpty) return null;
  return ShotTagger(chat: ArkChatClient(apiKey: credentials.arkApiKey));
}
