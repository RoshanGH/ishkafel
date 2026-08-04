// 探针：换音色全链路——听原声 → 得出语音指令 → 换音色合成 → 对齐到原时长。
//
// 产出一组可以直接听的对比样片，路径在输出里。
//
//   flutter test test/integration/voice_swap_probe_test.dart --tags integration --run-skipped
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/ai_credentials.dart';
import 'package:ishkafel/core/ai/ark_chat_client.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/audio/delivery_analyzer.dart';
import 'package:ishkafel/core/audio/prosody_profile.dart';
import 'package:ishkafel/core/audio/speech_alignment.dart';
import 'package:ishkafel/core/audio/tts_client.dart';

const _video =
    '/Users/menggang/Documents/滴露视频/JC_滴露_植源喷雾_XCT_SQ1&YY6_CH_千川直播_M66028501_0427.mp4';
const _text = '再不买就恢复69.9一瓶了。';
const _startMs = 80;
const _endMs = 2600;
const _voice = 'zh_female_vv_uranus_bigtts';

/// 那句的真实字级时间戳
const _words = [
  AsrWord(startMs: 80, endMs: 200, text: '再'),
  AsrWord(startMs: 200, endMs: 400, text: '不'),
  AsrWord(startMs: 400, endMs: 560, text: '买'),
  AsrWord(startMs: 680, endMs: 920, text: '就'),
  AsrWord(startMs: 920, endMs: 1120, text: '恢'),
  AsrWord(startMs: 1120, endMs: 1240, text: '复'),
  AsrWord(startMs: 1280, endMs: 2080, text: '69.9'),
  AsrWord(startMs: 2080, endMs: 2240, text: '一'),
  AsrWord(startMs: 2240, endMs: 2400, text: '瓶'),
  AsrWord(startMs: 2400, endMs: 2520, text: '了'),
];

Future<int> _durationMs(String path) async {
  final r = await Process.run('ffprobe', [
    '-v', 'quiet', '-show_entries', 'format=duration', '-of', 'csv=p=0', path,
  ]);
  final out = '${r.stdout}'.trim();
  return out.isEmpty ? 0 : (double.parse(out) * 1000).round();
}

void main() {
  final creds = CredentialsLoader.load(secretsDirs: [Directory('.secrets')]);
  final skip = creds.isComplete ? null : 'AI 凭据不完整';

  test('听原声 → 写指令 → 换音色 → 对齐时长', () async {
    if (!File(_video).existsSync()) {
      // ignore: avoid_print
      print('本机没有那条素材，跳过');
      return;
    }
    final out = Directory('${Platform.environment['HOME']}/Desktop/'
        'ishkafel_换音色对比');
    out.createSync(recursive: true);

    // ① 切出原声
    final original = '${out.path}/0_原声.wav';
    await Process.run('ffmpeg', [
      '-y', '-v', 'quiet',
      '-ss', '${_startMs / 1000}', '-to', '${_endMs / 1000}',
      '-i', _video, '-vn', '-ar', '16000', '-ac', '1', original,
    ]);
    final originalMs = await _durationMs(original);

    // ② 客观测量（给模型当佐证，也留痕）
    final prosody =
        ProsodyProfile.measure(words: _words, referenceCharsPerSec: 4.1);
    // ignore: avoid_print
    print('客观测量：${prosody.describe()}');

    // ③ 让模型听原声，写出语音指令
    final analysis = await ArkDeliveryAnalyzer(
      chat: ArkChatClient(apiKey: creds.arkApiKey),
    ).analyze(
      audioWav: File(original).readAsBytesSync(),
      transcript: _text,
      prosody: prosody,
    );
    // ignore: avoid_print
    print('模型听出来：${analysis.description}');
    // ignore: avoid_print
    print('生成的语音指令：${analysis.instruction}');
    expect(analysis.instruction, isNotEmpty,
        reason: '拿不到指令，这条链路就退化成「裸换音色」了');

    final tts = TtsClient(
        appId: creds.speechAppId, accessToken: creds.speechAccessToken);

    // ④ 对照组：不带指令
    final plain = await tts.synthesize(text: _text, speaker: _voice);
    File('${out.path}/1_换音色_无指令.mp3').writeAsBytesSync(plain.audio);

    // ⑤ 带指令
    final guided = await tts.synthesize(
        text: _text, speaker: _voice, instruction: analysis.instruction);
    final guidedPath = '${out.path}/2_换音色_带指令.mp3';
    File(guidedPath).writeAsBytesSync(guided.audio);
    final guidedMs = await _durationMs(guidedPath);

    // ⑥ 用测出来的差距重合成一遍，把时长压到原声上
    final rate =
        SpeechAlignment.rateFor(synthesizedMs: guidedMs, targetMs: originalMs);
    final aligned = await tts.synthesize(
      text: _text,
      speaker: _voice,
      instruction: analysis.instruction,
      speechRate: rate,
    );
    final alignedPath = '${out.path}/3_换音色_带指令_对齐.mp3';
    File(alignedPath).writeAsBytesSync(aligned.audio);
    final alignedMs = await _durationMs(alignedPath);

    // ignore: avoid_print
    print('\n原声 ${originalMs}ms');
    // ignore: avoid_print
    print('无指令 ${await _durationMs('${out.path}/1_换音色_无指令.mp3')}ms');
    // ignore: avoid_print
    print('带指令 ${guidedMs}ms → speech_rate $rate → 对齐后 ${alignedMs}ms '
        '（差 ${SpeechAlignment.residualMs(actualMs: alignedMs, targetMs: originalMs)}ms）');
    // ignore: avoid_print
    print('\n样片目录：${out.path}');

    expect(
      SpeechAlignment.residualMs(actualMs: alignedMs, targetMs: originalMs),
      lessThan(SpeechAlignment.residualMs(
          actualMs: guidedMs, targetMs: originalMs)),
      reason: '对齐之后反而离原声更远，那这一步就是白做的',
    );
  }, timeout: const Timeout(Duration(minutes: 5)), skip: skip);
}
