import 'dart:io';

import 'package:path/path.dart' as p;

import '../audio/tts_client.dart';
import '../log/app_log.dart';
import 'script_doc.dart';

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

  LineVoiceService({
    required this.tts,
    required this.outputDir,
    required this.measureMs,
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
    final result = await tts.synthesize(
      text: trimmed,
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
    return LineVoiceover(
      audioPath: file.path,
      durationMs: durationMs,
      sourceText: trimmed,
      voiceId: voiceId,
      speechRate: speechRate,
      words: [
        for (final w in result.words)
          VoiceWord(text: w.word, startMs: w.startMs, endMs: w.endMs),
      ],
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
