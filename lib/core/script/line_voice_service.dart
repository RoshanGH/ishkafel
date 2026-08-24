import 'dart:io';

import 'package:path/path.dart' as p;

import '../audio/tts_client.dart';
import '../log/app_log.dart';
import 'script_doc.dart';
import 'voice_qc.dart';

/// 编导台「生成配音」：一行台词 → TTS → mp3 落盘 → 量实际时长。
///
/// **显式触发**（设计稿）：改台词只把状态标黄，点了按钮才调 API 花钱。
/// 产物落 `<dataDir>/voices/<taskId>/`（TaskArtifacts 已收编该目录，
/// 删任务时随目录清走）；文件名带毫秒时间戳，同一行重新生成不覆盖旧文件
/// ——写一半崩了旧配音还在，生成成功后才删旧的。
class LineVoiceService {
  final TtsClient tts;
  final Directory outputDir;

  /// 量 mp3 的实际时长。配音时长是这一行时间轴的根，必须按实际音频量，
  /// 不能信字级时间戳的尾字（尾部常有静音）
  final Future<int> Function(File audio) measureMs;

  /// 给合成音频补词级时间戳（ASR 转写）。TTS 服务实测不回词级时间戳
  /// （enable_subtitle 只有句级文本），而字幕按镜头切分全靠词的时间——
  /// 「家人们」归第一镜、后半句归后面的镜头。null = 不补（老装配）；
  /// 抛异常不挡配音，words 留空、字幕退回整句
  final Future<List<VoiceWord>> Function(File audio)? transcribeWords;

  LineVoiceService({
    required this.tts,
    required this.outputDir,
    required this.measureMs,
    this.transcribeWords,
  });

  /// 为一行生成配音。失败抛 [TtsException]（中文、可直接展示）。
  Future<LineVoiceover> generate({
    required String lineId,
    required String text,
    required String voiceId,
    int speechRate = 0,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw const TtsException('这一行没有台词，没法配音。');
    }
    // 抽风了就重来一次：大模型 TTS 会陷进重复解码（后半句两个词一直
    // 重复）或半截断掉。这类音频听着就是「卡住了」，不能进成片。
    // 质检用的是已经在做的那次 ASR 转写，不额外花钱（见 voice_qc.dart）
    String? lastDefect;
    for (var attempt = 0; attempt < 2; attempt++) {
      final vo = await _synthesizeOnce(
        lineId: lineId,
        text: trimmed,
        voiceId: voiceId,
        speechRate: speechRate,
      );
      final defect = voiceDefect(
        source: trimmed,
        heard: vo.words,
        durationMs: vo.durationMs,
      );
      if (defect == null) return vo;
      lastDefect = defect;
      AppLog.warn('配音念岔了，重来一次（line=$lineId，第 ${attempt + 1} 次）：$defect');
      // 坏的这份立刻删掉，不留孤儿
      try {
        File(vo.audioPath).deleteSync();
      } catch (_) {}
    }
    // 两次都念岔——不静默：宁可让人知道这一句要处理，也不把卡住的
    // 声音放进成片
    throw TtsException('$lastDefect。已经自动重试过一次还是这样，'
        '可以改一改这句台词（拆短、去掉重复的词）再生成。');
  }

  /// 合成一次并落盘：TTS → mp3 → 量时长 → 补词级时间戳
  Future<LineVoiceover> _synthesizeOnce({
    required String lineId,
    required String text,
    required String voiceId,
    required int speechRate,
  }) async {
    final result = await tts.synthesize(
      text: text,
      speaker: voiceId,
      speechRate: speechRate == 0 ? null : speechRate,
    );
    await outputDir.create(recursive: true);
    final file = File(p.join(outputDir.path,
        '${lineId}_${DateTime.now().millisecondsSinceEpoch}.mp3'));
    await file.writeAsBytes(result.audio);
    final durationMs = await measureMs(file);
    if (durationMs <= 0) {
      // 空音频当失败：0 时长的「根」会把整行时间轴归零
      try {
        file.deleteSync();
      } catch (_) {}
      throw const TtsException('合成出的音频是空的，请重试。');
    }
    var words = [
      for (final w in result.words)
        VoiceWord(text: w.word, startMs: w.startMs, endMs: w.endMs),
    ];
    if (words.isEmpty && transcribeWords != null) {
      try {
        words = await transcribeWords!(file);
      } catch (e) {
        AppLog.warn('配音词级时间戳转写失败（line=$lineId，字幕退回整句）：$e');
        words = const [];
      }
    }
    return LineVoiceover(
      audioPath: file.path,
      durationMs: durationMs,
      sourceText: text,
      voiceId: voiceId,
      speechRate: speechRate,
      words: words,
    );
  }

  /// 删掉一份被替代的旧配音文件。删不掉只留日志——孤儿文件由
  /// TaskArtifacts 的按任务清理兜底
  void deleteStale(LineVoiceover old) {
    try {
      File(old.audioPath).deleteSync();
    } catch (e) {
      AppLog.warn('旧配音删除失败（${old.audioPath}）：$e');
    }
  }
}
