// 探针：火山 TTS 到底能控到什么程度——情感标签、语速、以及同一句话在不同
// 音色下的时长差异。用来评估「换音色但保持原有感情与语速」能做到几分。
//
//   flutter test test/integration/tts_prosody_probe_test.dart --tags integration --run-skipped
@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/ai_credentials.dart';
import 'package:ishkafel/core/net/json_poster.dart';

final _endpoint = Uri.parse('https://openspeech.bytedance.com/api/v1/tts');

/// 那条片子 U1 的真实台词与真实时长（字级时间戳算出来的）
const _text = '再不买就恢复69.9一瓶了。';
const _originalMs = 2520; // 80ms → 2600ms

/// 试三类音色：普通、多情感、以及一个偏播报的
const _voices = <String, String>{
  'BV001_streaming': '通用女声',
  'BV700_streaming': '灿灿（多情感）',
  'BV406_streaming': '温柔小哥',
};

/// 多情感音色支持的情感标签（挑几个与带货口播相关的试）
const _emotions = ['neutral', 'happy', 'excited', 'angry'];

Future<({int status, dynamic code, String? message, int bytes})> _synth({
  required String appId,
  required String token,
  required String voice,
  String? emotion,
  double speed = 1.0,
}) async {
  final r = await httpJsonPoster(
    _endpoint,
    {'Authorization': 'Bearer;$token'},
    jsonEncode({
      'app': {'appid': appId, 'token': token, 'cluster': 'volcano_tts'},
      'user': {'uid': 'ishkafel-prosody-probe'},
      'audio': {
        'voice_type': voice,
        'encoding': 'mp3',
        'speed_ratio': speed,
        'emotion': ?emotion,
      },
      'request': {
        'reqid': '${DateTime.now().microsecondsSinceEpoch}',
        'text': _text,
        'operation': 'query',
      },
    }),
  );
  Map<String, dynamic> json;
  try {
    json = jsonDecode(r.body) as Map<String, dynamic>;
  } catch (_) {
    json = const {};
  }
  final data = json['data'];
  return (
    status: r.statusCode,
    code: json['code'],
    message: (json['message'] ?? json['Message'])?.toString(),
    bytes: data is String ? base64Decode(data).length : 0,
  );
}

void main() {
  final creds = CredentialsLoader.load(secretsDirs: [Directory('.secrets')]);
  final skip = creds.isComplete ? null : '语音凭据不完整';

  test('情感标签是否被接受', () async {
    for (final emotion in _emotions) {
      final r = await _synth(
        appId: creds.speechAppId,
        token: creds.speechAccessToken,
        voice: 'BV700_streaming',
        emotion: emotion,
      );
      // ignore: avoid_print
      print('emotion=${emotion.padRight(9)} code=${r.code} '
          '${r.bytes > 0 ? "${(r.bytes / 1024).round()}KB" : "失败 ${r.message}"}');
    }
  }, timeout: const Timeout(Duration(minutes: 3)), skip: skip);

  test('语速参数的可控范围（用于把合成时长对齐到原声）', () async {
    for (final speed in [0.8, 1.0, 1.2, 1.5, 2.0]) {
      final r = await _synth(
        appId: creds.speechAppId,
        token: creds.speechAccessToken,
        voice: 'BV001_streaming',
        speed: speed,
      );
      // ignore: avoid_print
      print('speed=$speed code=${r.code} '
          '${r.bytes > 0 ? "${(r.bytes / 1024).round()}KB" : "失败 ${r.message}"}');
    }
  }, timeout: const Timeout(Duration(minutes: 3)), skip: skip);

  test('同一句话不同音色的自然时长差多少（原声 ${_originalMs}ms）', () async {
    final outDir = Directory.systemTemp.createTempSync('ishkafel_tts_');
    // ignore: avoid_print
    print('样片目录：${outDir.path}');
    for (final entry in _voices.entries) {
      final r = await _synth(
        appId: creds.speechAppId,
        token: creds.speechAccessToken,
        voice: entry.key,
      );
      // ignore: avoid_print
      print('${entry.value.padRight(12)} code=${r.code} '
          '${(r.bytes / 1024).toStringAsFixed(1)}KB');
    }
  }, timeout: const Timeout(Duration(minutes: 3)), skip: skip);
}
