import 'dart:io';

import 'package:path/path.dart' as p;

import '../analysis/audio_extractor.dart';
import '../analysis/providers.dart';
import '../analysis/segmentation_builder.dart';
import 'script_doc.dart';

/// 提取进行到哪一步了——界面拿它给用户交代（等待必须有交代）
enum ScriptTranscribeStage {
  extractingAudio('正在读取视频音频'),
  transcribing('正在识别台词'),
  splitting('正在按语义分行');

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

/// 「上传成片 → ASR → 语义断句 → 脚本行」。
///
/// 脚本的两个来源之一（另一个是手写）：编导手里往往已经有一条参考成片，
/// 台词照着念一遍 ASR 就有了，没必要逐句敲。断句复用成片翻新分析里同一个
/// 语义切分（一段一个完整意思），出来的每个单元就是一行台词。
///
/// 只产出**文本行**，不带时间戳进脚本——脚本成片里行的时长由配音定
/// （「配音时长是根」），参考片的原始时间轴在这里没有意义。
class ScriptTranscriber {
  final AudioExtractor audio;
  final AsrProvider asr;
  final SemanticSplitter splitter;

  /// PCM 中间产物的落脚处（用完即删，不留孤儿数据）
  final Directory workDir;

  ScriptTranscriber({
    required this.audio,
    required this.asr,
    required this.splitter,
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
      if (sentences.every((s) => s.text.trim().isEmpty)) {
        throw const ScriptTranscribeException(
            '这条视频里没有识别到任何台词——请确认它有人声口播。');
      }

      onStage?.call(ScriptTranscribeStage.splitting);
      List<UnitDraft> drafts;
      try {
        drafts = await splitter.split(sentences);
      } catch (e) {
        throw ScriptTranscribeException(
            '语义分行失败（AI 服务不可用或网络异常），请稍后重试。', cause: e);
      }
      // 断句结果不可靠时退回「一句一行」：宁可行多让人合并，不能空手而归
      if (drafts.isEmpty) {
        drafts = [
          for (final s in sentences)
            if (s.text.trim().isNotEmpty)
              UnitDraft(startMs: s.startMs, endMs: s.endMs, transcript: s.text),
        ];
      }
      return [
        for (final d in drafts)
          if (d.transcript.trim().isNotEmpty)
            ScriptLine.create(text: d.transcript.trim()),
      ];
    } finally {
      // 中间产物用完即弃（几分钟的 PCM 有几十 MB）
      try {
        File(pcmPath).deleteSync();
      } catch (_) {}
    }
  }
}
