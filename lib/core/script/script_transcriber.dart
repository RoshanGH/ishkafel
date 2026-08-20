import 'dart:io';

import 'package:path/path.dart' as p;

import '../analysis/audio_extractor.dart';
import '../analysis/providers.dart';
import 'script_doc.dart';

/// 提取进行到哪一步了——界面拿它给用户交代（等待必须有交代）
enum ScriptTranscribeStage {
  extractingAudio('正在读取视频音频'),
  transcribing('正在识别台词');

  final String label;
  const ScriptTranscribeStage(this.label);
}

/// 提取失败：message 面向用户（中文、说清下一步），cause 只进日志
class ScriptTranscribeException implements Exception {
  final String message;
  final Object? cause;
  const ScriptTranscribeException(this.message, {this.cause});
  @override
  String toString() => message;
}

/// 「上传成片 → ASR → 脚本行」。
///
/// 脚本的两个来源之一（另一个是手写）：编导手里往往已经有一条参考成片，
/// 台词照着念一遍 ASR 就有了，没必要逐句敲。
///
/// **一句一行**：脚本行的粒度是「一句可配音的话」，直接取 ASR 按停顿切出
/// 的句子。不复用成片翻新的语义单元切分——那是段落级（一个卖点一段），
/// 拿来当脚本行会切出半篇文章长的行（真机验证撞到过）。
///
/// 只产出**文本行**，不带时间戳进脚本——脚本成片里行的时长由配音定
/// （「配音时长是根」），参考片的原始时间轴在这里没有意义。
class ScriptTranscriber {
  final AudioExtractor audio;
  final AsrProvider asr;

  /// PCM 中间产物的落脚处（用完即删，不留孤儿数据）
  final Directory workDir;

  ScriptTranscriber({
    required this.audio,
    required this.asr,
    required this.workDir,
  });

  /// 从视频提取脚本行。[onStage] 每进一步回调一次，供界面交代进度。
  ///
  /// 一句都识别不出来时抛 [ScriptTranscribeException]——静默返回空脚本
  /// 会让用户以为软件坏了。
  Future<List<ScriptLine>> extract(
    String videoPath, {
    void Function(ScriptTranscribeStage stage)? onStage,
  }) async {
    if (!File(videoPath).existsSync()) {
      throw ScriptTranscribeException('找不到这个视频文件：$videoPath');
    }
    await workDir.create(recursive: true);
    final pcmPath = p.join(workDir.path,
        'script_asr_${DateTime.now().microsecondsSinceEpoch}.pcm');
    try {
      onStage?.call(ScriptTranscribeStage.extractingAudio);
      try {
        await audio.extractSamples(videoPath: videoPath, outPcmPath: pcmPath);
      } catch (e) {
        throw ScriptTranscribeException(
            '读取视频音频失败，请确认文件是完整的视频且本机 ffmpeg 可用。',
            cause: e);
      }

      onStage?.call(ScriptTranscribeStage.transcribing);
      final List<AsrSentence> sentences;
      try {
        sentences = await asr.transcribe(pcmPath);
      } catch (e) {
        throw ScriptTranscribeException(
            '台词识别失败（语音服务不可用或网络异常），请稍后重试。',
            cause: e);
      }
      final lines = [
        for (final s in sentences)
          if (s.text.trim().isNotEmpty)
            ScriptLine.create(
              text: s.text.trim(),
              // 这一句在参考片里的区间：右栏「参考视频」列的数据根
              reference: s.endMs > s.startMs
                  ? LineRef(startMs: s.startMs, endMs: s.endMs)
                  : null,
            ),
      ];
      if (lines.isEmpty) {
        throw const ScriptTranscribeException(
            '这条视频里没有识别到任何台词——请确认它有人声口播。');
      }
      return lines;
    } finally {
      // 中间产物用完即弃（几分钟的 PCM 有几十 MB）
      try {
        File(pcmPath).deleteSync();
      } catch (_) {}
    }
  }
}
