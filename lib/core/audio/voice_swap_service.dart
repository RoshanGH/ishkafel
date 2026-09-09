import 'dart:typed_data';

import '../analysis/providers.dart';
import '../log/app_log.dart';
import '../models/semantic_unit.dart';
import 'delivery_analyzer.dart';
import 'prosody_profile.dart';
import 'speech_alignment.dart';
import 'tts_client.dart';
import 'voice_plan.dart';

/// 一个单元换音色的产物
class VoiceSwapResult {
  final Uint8List audio;

  /// 这次用的语音指令与它的来源分析，供界面展示与留痕
  final DeliveryAnalysis analysis;

  /// 合成出来的时长与目标（原单元）时长
  final int synthesizedMs;
  final int targetMs;

  /// 还差多少毫秒。上层据此决定要不要再挂一道 atempo，
  /// 或者如实告诉用户「这一句对不齐」
  int get residualMs =>
      SpeechAlignment.residualMs(actualMs: synthesizedMs, targetMs: targetMs);

  const VoiceSwapResult({
    required this.audio,
    required this.analysis,
    required this.synthesizedMs,
    required this.targetMs,
  });
}

/// 把「听原声 → 写指令 → 换音色合成 → 对齐时长」串成一件事。
///
/// 只处理**被指定了音色**的单元：没指定的保持原声，一个字节都不碰——用户往往
/// 只想换其中几句，给其余单元也跑一遍分析纯属白花钱。
class VoiceSwapService {
  final TtsClient tts;
  final DeliveryAnalyzer analyzer;

  /// 从原片里切出 `[startMs, endMs)` 的音频（WAV）。注入而不是内建 ffmpeg 调用：
  /// 这一层要能在不碰真实进程的情况下测。
  final Future<List<int>> Function(int startMs, int endMs) sliceOriginal;

  /// 量一段音频有多长（毫秒）。同样注入——曾经想用「字节数 ÷ 比特率」估，
  /// 但 mp3 是变比特率的，估出来的偏差直接喂进对齐逻辑，会让本来准的一句
  /// 被改得更歪。生产上用 ffprobe 量准。
  final Future<int> Function(List<int> audio) measureMs;

  /// 每个单元的失败原因（成功的不在里面）。一个单元失败不该让整批停下——
  /// 十句里坏一句，重跑那一句就行。
  final Map<String, String> failures = {};

  VoiceSwapService({
    required this.tts,
    required this.analyzer,
    required this.sliceOriginal,
    required this.measureMs,
  });

  /// 合成出来与目标差多少就重来一次。低于这个比例不值得多花一次调用。
  static const double _realignThreshold = 0.06;

  /// 结果按**单元的身份**记（[SemanticUnit.uid]）：按下标记的话，人挪一次
  /// 单元，本该念 U3 的那段就跑到 U2 身上——不报错，只有听出来才知道
  Future<Map<String, VoiceSwapResult>> run({
    required List<SemanticUnit> units,
    required List<AsrSentence> sentences,
    required VoicePlan plan,
    void Function(int done, int total)? onProgress,
  }) async {
    failures.clear();
    final targets = [
      for (final unit in units)
        if (plan.assignedUnits.contains(unit.uid)) unit,
    ];
    if (targets.isEmpty) return const {};

    final reference = _referenceCharsPerSec(sentences);
    final out = <String, VoiceSwapResult>{};
    var done = 0;
    onProgress?.call(0, targets.length);

    for (final unit in targets) {
      final voice = plan.voiceOf(unit.uid);
      if (voice == null) continue;
      try {
        out[unit.uid] = await _swapOne(unit, voice, sentences, reference);
      } catch (e) {
        AppLog.warn('单元 ${unit.index} 换音色失败：$e');
        failures[unit.uid] = '$e';
      }
      onProgress?.call(++done, targets.length);
    }
    return Map.unmodifiable(out);
  }

  Future<VoiceSwapResult> _swapOne(
    SemanticUnit unit,
    VoiceRef voice,
    List<AsrSentence> sentences,
    double reference,
  ) async {
    final targetMs = unit.durationMs;
    final original = await sliceOriginal(unit.startMs, unit.endMs);
    final prosody = ProsodyProfile.measure(
      words: _wordsIn(sentences, unit.startMs, unit.endMs),
      referenceCharsPerSec: reference,
    );
    final analysis = await analyzer.analyze(
      audioWav: original,
      transcript: unit.transcript,
      prosody: prosody,
    );

    // 第一次是探路：不带语速，看这个音色念这句话自然要多久
    final first = await tts.synthesize(
      text: unit.transcript,
      speaker: voice.id,
      instruction: analysis.instruction.isEmpty ? null : analysis.instruction,
    );
    final firstMs = await measureMs(first.audio);

    final rate =
        SpeechAlignment.rateFor(synthesizedMs: firstMs, targetMs: targetMs);
    final offBy = targetMs > 0 ? (firstMs - targetMs).abs() / targetMs : 0.0;
    if (rate == 0 || offBy < _realignThreshold) {
      return VoiceSwapResult(
        audio: first.audio,
        analysis: analysis,
        synthesizedMs: firstMs,
        targetMs: targetMs,
      );
    }

    // 第二次带上算出来的语速。让模型自己用更快/更慢的节奏重念一遍，
    // 比事后把音频拉伸自然得多。
    final second = await tts.synthesize(
      text: unit.transcript,
      speaker: voice.id,
      instruction: analysis.instruction.isEmpty ? null : analysis.instruction,
      speechRate: rate,
    );
    return VoiceSwapResult(
      audio: second.audio,
      analysis: analysis,
      synthesizedMs: await measureMs(second.audio),
      targetMs: targetMs,
    );
  }

  /// 落到该单元范围内的字级时间戳
  static List<AsrWord> _wordsIn(
          List<AsrSentence> sentences, int startMs, int endMs) =>
      [
        for (final s in sentences)
          for (final w in s.words)
            if (w.startMs >= startMs && w.endMs <= endMs) w,
      ];

  /// 全片的平均语速，用来判断某一段是偏快还是偏慢
  static double _referenceCharsPerSec(List<AsrSentence> sentences) {
    var chars = 0;
    var ms = 0;
    for (final s in sentences) {
      if (s.endMs <= s.startMs) continue;
      chars += s.text.length;
      ms += s.endMs - s.startMs;
    }
    return ms > 0 ? chars * 1000 / ms : 0;
  }

}
