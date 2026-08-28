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
