import 'dart:io';

import 'package:file_selector/file_selector.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/ai/ai_credentials.dart';
import '../../core/ai/ark_chat_client.dart';
import '../../core/ai/taggers.dart';
import '../../core/ai/volcano_asr_provider.dart';
import '../../core/audio/tts_client.dart';
import '../../core/ffmpeg/process_runner.dart';
import '../../core/log/app_log.dart';
import '../../core/miaoa/candidate_probe.dart';
import '../../core/miaoa/miaoa_content_service.dart';
import '../../core/miaoa/miaoa_tag_service.dart';
import '../../core/models/renew_task.dart';
import '../../core/script/line_tagger.dart';
import '../../core/script/line_voice_service.dart';
import '../../core/script/script_doc.dart' show VoiceWord;
import '../../core/script/script_transcriber.dart';

/// 「从视频提取脚本」的服务。null = AI 凭据不全——编导台把入口禁用并
/// 说明原因，绝不让用户点了之后撞网络错误。真实实例在 main.dart 注入
/// （见 service_wiring.buildScriptTranscriber）。
final scriptTranscriberProvider = Provider<ScriptTranscriber?>((ref) => null);

/// 行台词打标（复用 U 层打标管线）。null = 方舟凭据缺失，
/// 「自动打标」禁用并说明原因。真实实例在 main.dart 注入
final lineTaggerProvider = Provider<LineTagger?>((ref) => null);

/// 参考素材选择器：视频或图片都收（手动传参考时用）。
/// 单测 override 成假实现，不弹真实系统文件框
typedef RefFilePicker = Future<String?> Function();

final refFilePickerProvider = Provider<RefFilePicker>((ref) => pickRefFile);

Future<String?> pickRefFile() async {
  const video = XTypeGroup(label: '参考视频', extensions: ['mp4', 'mov']);
  const image =
      XTypeGroup(label: '参考图', extensions: ['jpg', 'jpeg', 'png', 'webp']);
  final file = await openFile(acceptedTypeGroups: const [video, image]);
  return file?.path;
}

/// 参考视觉镜头打标（多帧 vision，一次给标签 + 画面描述——与 U 层
/// 视觉镜头打标同一个 ShotTagger）。null = 方舟凭据缺失
final refShotTaggerProvider = Provider<ShotTagger?>((ref) => null);

ShotTagger? buildRefShotTagger(AiCredentials credentials) {
  if (credentials.arkApiKey.isEmpty) return null;
  return ShotTagger(chat: ArkChatClient(apiKey: credentials.arkApiKey));
}

/// 找镜头面板的三件套：内容检索、规格探测、标签体系。
/// 默认真实实例（构造不起子进程，真正调用才 exec）；单测 override
final shotSearchServicesProvider = Provider<ShotSearchServices>(
    (ref) => ShotSearchServices(
          content: MiaoaContentService(),
          probe: CandidateProbe(),
          tags: MiaoaTagService(),
        ));

class ShotSearchServices {
  final MiaoaContentService content;
  final CandidateProbe probe;
  final MiaoaTagService tags;

  const ShotSearchServices(
      {required this.content, required this.probe, required this.tags});
}

/// 按任务造「生成配音」服务。null = 语音凭据不全，配音节禁用并说明原因
typedef LineVoiceFactory = LineVoiceService Function(RenewTask task);

final lineVoiceFactoryProvider = Provider<LineVoiceFactory?>((ref) => null);

/// 真实装配：TTS 走豆包 2.0，产物落 `<dataDir>/voices/<taskId>/`
/// （与工作台换音色同一目录规矩，TaskArtifacts 收编、删任务随目录清走）。
/// 词级时间戳由 ASR 对合成音频转写补上（TTS 服务不回词级），
/// 字幕才能按镜头切分——「家人们」归第一镜，后半句归后面的镜头
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
        measureMs: _measureFileMs,
        transcribeWords: (audio) => _transcribeVoiceWords(asr, audio),
      );
}

/// mp3 → 16k 单声道 PCM（临时文件，用完即删）→ ASR → 词级时间戳
Future<List<VoiceWord>> _transcribeVoiceWords(
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

/// 用 ffprobe 量 mp3 实际时长——配音时长是行时间轴的根，不能按比特率估
Future<int> _measureFileMs(File audio) async {
  final r = await systemProcessRunner('ffprobe', [
    '-v', 'quiet', '-show_entries', 'format=duration', '-of', 'csv=p=0',
    audio.path,
  ]);
  final seconds = double.tryParse('${r.stdout}'.trim());
  if (seconds == null) {
    AppLog.warn('量不出配音时长（${audio.path}）');
    return 0;
  }
  return (seconds * 1000).round();
}
