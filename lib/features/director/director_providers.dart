import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/ai/ai_credentials.dart';
import '../../core/audio/tts_client.dart';
import '../../core/ffmpeg/process_runner.dart';
import '../../core/log/app_log.dart';
import '../../core/models/renew_task.dart';
import '../../core/script/line_voice_service.dart';
import '../../core/script/script_transcriber.dart';

/// 「从视频提取脚本」的服务。null = AI 凭据不全——编导台把入口禁用并
/// 说明原因，绝不让用户点了之后撞网络错误。真实实例在 main.dart 注入
/// （见 service_wiring.buildScriptTranscriber）。
final scriptTranscriberProvider = Provider<ScriptTranscriber?>((ref) => null);

/// 按任务造「生成配音」服务。null = 语音凭据不全，配音节禁用并说明原因
typedef LineVoiceFactory = LineVoiceService Function(RenewTask task);

final lineVoiceFactoryProvider = Provider<LineVoiceFactory?>((ref) => null);

/// 真实装配：TTS 走豆包 2.0，产物落 `<dataDir>/voices/<taskId>/`
/// （与工作台换音色同一目录规矩，TaskArtifacts 收编、删任务随目录清走）
LineVoiceFactory? defaultLineVoiceFactory(
    AiCredentials credentials, Directory dataDir) {
  if (credentials.speechAppId.isEmpty ||
      credentials.speechAccessToken.isEmpty) {
    return null;
  }
  return (task) => LineVoiceService(
        tts: TtsClient(
          appId: credentials.speechAppId,
          accessToken: credentials.speechAccessToken,
        ),
        outputDir: Directory(p.join(dataDir.path, 'voices', task.id)),
        measureMs: _measureFileMs,
      );
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
