import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/ai/ark_chat_client.dart';
import '../../core/audio/delivery_analyzer.dart';
import '../../core/audio/tts_client.dart';
import '../../core/audio/voice_swap_service.dart';
import '../../core/ffmpeg/process_runner.dart';
import '../../core/log/app_log.dart';

/// 换音色服务的装配点：把真实的 ffmpeg 切片、ffprobe 量时长、云端客户端接起来。
///
/// null 表示凭据未配置——界面据此把「生成配音」禁用并说明原因，
/// 而不是让用户点了之后撞一个网络错误。
final voiceSwapServiceProvider = Provider<VoiceSwapService?>((ref) => null);

/// 用真实工具链造一个可用的服务
VoiceSwapService buildVoiceSwapService({
  required String arkApiKey,
  required String speechAppId,
  required String speechAccessToken,
  required String sourcePath,
  required Directory workDir,
  ProcessRunner? run,
}) {
  // 复用 ResolvingProcessRunner：GUI 进程的 PATH 里没有 Homebrew 目录，
  // 直接 Process.run('ffmpeg') 在打包版上必然找不到——这个坑本项目踩过，
  // 定位与人话报错都在那个类里，不要再写一遍
  final exec = run ?? const ResolvingProcessRunner().call;
  return VoiceSwapService(
    tts: TtsClient(appId: speechAppId, accessToken: speechAccessToken),
    analyzer: ArkDeliveryAnalyzer(chat: ArkChatClient(apiKey: arkApiKey)),
    sliceOriginal: (startMs, endMs) =>
        _slice(exec, sourcePath, workDir, startMs, endMs),
    measureMs: (audio) => _measure(exec, workDir, audio),
  );
}

/// 从原片切出一段 16kHz 单声道 WAV——多模态模型吃的就是这个规格
Future<List<int>> _slice(ProcessRunner exec, String sourcePath,
    Directory workDir, int startMs, int endMs) async {
  workDir.createSync(recursive: true);
  final out = p.join(workDir.path, 'slice_${startMs}_$endMs.wav');
  final r = await exec('ffmpeg', [
    '-y', '-v', 'quiet',
    '-ss', '${startMs / 1000}', '-to', '${endMs / 1000}',
    '-i', sourcePath,
    '-vn', '-ar', '16000', '-ac', '1', out,
  ]);
  if (r.exitCode != 0 || !File(out).existsSync()) {
    throw Exception('切出原声失败（$startMs~$endMs ms）');
  }
  return File(out).readAsBytesSync();
}

/// 用 ffprobe 量准时长。
///
/// 不用「字节数 ÷ 比特率」估：mp3 是变比特率的，估出来的偏差会直接喂进
/// 对齐逻辑，把本来准的一句改得更歪。
Future<int> _measure(
    ProcessRunner exec, Directory workDir, List<int> audio) async {
  workDir.createSync(recursive: true);
  final tmp = File(p.join(workDir.path, 'measure.mp3'))..writeAsBytesSync(audio);
  final r = await exec('ffprobe', [
    '-v', 'quiet', '-show_entries', 'format=duration', '-of', 'csv=p=0',
    tmp.path,
  ]);
  final text = '${r.stdout}'.trim();
  final seconds = double.tryParse(text);
  if (seconds == null) {
    // 量不出来时返回 0：上层的对齐逻辑会因此判定「不知道多长」而跳过调整，
    // 总比拿一个瞎猜的时长去改语速强
    AppLog.warn('量不出合成音频时长，本句跳过时长对齐');
    return 0;
  }
  return (seconds * 1000).round();
}
