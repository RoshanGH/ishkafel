import 'dart:io';

import 'package:path/path.dart' as p;

import '../ai/ai_credentials.dart';
import '../models/renew_task.dart';
import '../ai/ark_chat_client.dart';
import 'delivery_analyzer.dart';
import 'tts_client.dart';
import '../ffmpeg/process_runner.dart';
import '../log/app_log.dart';
import 'voice_swap_service.dart';

/// 一次配音生成要用的东西：服务本身 + 产物落在哪。
///
/// 产物必须落成文件而不是只在内存里：生成一轮要几十秒到几分钟，
/// 关掉页面就没了的话用户得重跑一遍。
class VoiceSwapJob {
  final VoiceSwapService service;
  final Directory outputDir;

  const VoiceSwapJob({required this.service, required this.outputDir});

  /// 某个台词语义单元的配音文件（不保证存在）。
  ///
  /// **按单元的身份命名**（[SemanticUnit.uid]），不按位置：文件名里写下标的
  /// 话，人挪一次单元，方案里的指向被搬走了、盘上那个 mp3 还叫原来的名字，
  /// 取到的就是**另一个单元的配音**——不报错，只有听出来才知道
  /// （2026-09-09 清点时查出来的）。
  File audioFor(String unitUid) =>
      File(p.join(outputDir.path, 'unit_$unitUid.mp3'));

  /// 已经生成过的那些——重开页面时据此恢复「可试听」状态
  Map<String, String> existingAudio(Iterable<String> unitUids) => {
        for (final uid in unitUids)
          if (audioFor(uid).existsSync()) uid: audioFor(uid).path,
      };
}

/// 按任务造一个配音作业。任务不同，原片与产物目录都不同，所以是工厂而不是
/// 单例服务。
/// 返回 null 表示这条任务换不了音色（空白任务没有台词）——
/// 界面据此禁用按钮并说明原因，而不是让用户点了之后撞一个空指针
typedef VoiceSwapFactory = VoiceSwapJob? Function(RenewTask task);

/// 生产装配：凭据齐了才给工厂，否则返回 null（界面据此禁用按钮）
VoiceSwapFactory? defaultVoiceSwapFactory({
  required AiCredentials credentials,
  required Directory dataDir,
}) {
  if (!credentials.isComplete) return null;
  return (task) {
    // 空白任务没有台词，也就没有音色可换
    final sourcePath = task.sourcePath;
    if (sourcePath == null) return null;
    return VoiceSwapJob(
      service: buildVoiceSwapService(
        arkApiKey: credentials.arkApiKey,
        speechAppId: credentials.speechAppId,
        speechAccessToken: credentials.speechAccessToken,
        sourcePath: sourcePath,
        // 切片是中间产物，跟分析的临时文件放一块，清理缓存时一并带走
        workDir: Directory(p.join(dataDir.path, 'analysis_work')),
      ),
      // 产物按任务分目录：任务删掉时整个目录一并删，不会留下孤儿音频
      outputDir: Directory(p.join(dataDir.path, 'voices', task.id)),
    );
  };
}

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
