// 探针：Dart 版 TTS 客户端打通豆包 2.0 的 WebSocket 双向流。
//
//   flutter test test/integration/tts_client_probe_test.dart --tags integration --run-skipped
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/ai_credentials.dart';
import 'package:ishkafel/core/audio/tts_client.dart';

/// 那条片子 U1 的真实台词与真实时长（字级时间戳 80→2600）
const _text = '再不买就恢复69.9一瓶了。';
const _originalMs = 2520;
const _voice = 'zh_female_vv_uranus_bigtts';

void main() {
  final creds = CredentialsLoader.load(secretsDirs: [Directory('.secrets')]);
  final skip = creds.isComplete ? null : '语音凭据不完整';

  TtsClient client() => TtsClient(
      appId: creds.speechAppId, accessToken: creds.speechAccessToken);

  test('能出音', () async {
    final r = await client().synthesize(text: _text, speaker: _voice);

    expect(r.audio.length, greaterThan(1000));
    // ignore: avoid_print
    print('音频 ${r.audio.length} 字节，字级时间戳 ${r.words.length} 个');
    // 现状记录：`enable_subtitle` 开着，服务端回的字幕包里 text 有内容、
    // words 恒为空数组（换纯中文、关掉该参数都一样）。对齐用总时长即可，
    // 词级时间戳只影响更细的节奏匹配，不阻塞流程。等这个能力可用时，
    // 这里改成断言非空即可。
  }, timeout: const Timeout(Duration(minutes: 2)), skip: skip);

  test('语音指令与语速参数都被接受', () async {
    final r = await client().synthesize(
      text: _text,
      speaker: _voice,
      instruction: '你可以用非常着急、语速很快的语气催促观众吗？',
      speechRate: 20,
    );

    expect(r.audio.length, greaterThan(1000));
    if (r.words.isNotEmpty) {
      // ignore: avoid_print
      print('带指令合成：末字结束于 ${r.words.last.endMs}ms（原声 ${_originalMs}ms）');
    }
  }, timeout: const Timeout(Duration(minutes: 2)), skip: skip);

  test('音色不存在时抛出可读的中文，而不是静默返回空音频', () async {
    await expectLater(
      client().synthesize(
          text: _text,
          speaker: '根本不存在的音色',
          timeout: const Duration(seconds: 20)),
      throwsA(isA<TtsException>()),
    );
  }, timeout: const Timeout(Duration(minutes: 2)), skip: skip);
}
