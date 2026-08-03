// 探针：确认火山 TTS 能否用现有语音凭据跑通，以及可用音色。
//
//   flutter test test/integration/tts_probe_test.dart --tags integration --run-skipped
@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/ai_credentials.dart';
import 'package:ishkafel/core/net/json_poster.dart';

/// 火山 TTS（HTTP 一次性合成）
final _endpoint = Uri.parse('https://openspeech.bytedance.com/api/v1/tts');

/// 挑几个常见音色试；能合成的说明该音色在这个账号下可用
const _voices = <String, String>{
  'BV001_streaming': '通用女声',
  'BV002_streaming': '通用男声',
  'BV700_streaming': '灿灿（多情感）',
  'BV406_streaming': '温柔小哥',
};

const _text = '再不买就恢复六十九块九一瓶了。';

Future<(int, Map<String, dynamic>)> _synth(
    String appId, String token, String voice) async {
  final r = await httpJsonPoster(
    _endpoint,
    {'Authorization': 'Bearer;$token'},
    jsonEncode({
      'app': {'appid': appId, 'token': token, 'cluster': 'volcano_tts'},
      'user': {'uid': 'ishkafel-probe'},
      'audio': {
        'voice_type': voice,
        'encoding': 'mp3',
        'speed_ratio': 1.0,
      },
      'request': {
        'reqid': DateTime.now().microsecondsSinceEpoch.toString(),
        'text': _text,
        'operation': 'query',
      },
    }),
  );
  Map<String, dynamic> json;
  try {
    json = jsonDecode(r.body) as Map<String, dynamic>;
  } catch (_) {
    json = {'raw': r.body.length > 200 ? '${r.body.substring(0, 200)}…' : r.body};
  }
  return (r.statusCode, json);
}

void main() {
  final creds = CredentialsLoader.load(secretsDirs: [Directory('.secrets')]);
  final skip = creds.isComplete ? null : '语音凭据不完整';

  test('火山 TTS 可用性与音色', () async {
    for (final entry in _voices.entries) {
      final (status, json) =
          await _synth(creds.speechAppId, creds.speechAccessToken, entry.key);
      final code = json['code'];
      final message = json['message'] ?? json['Message'] ?? json['raw'];
      final data = json['data'];
      final audioBytes =
          data is String ? base64Decode(data).length : 0;
      // ignore: avoid_print
      print('${entry.value.padRight(12)} ${entry.key.padRight(18)} '
          'HTTP $status code=$code '
          '${audioBytes > 0 ? "音频 ${(audioBytes / 1024).round()}KB" : "message=$message"}');
    }
  }, timeout: const Timeout(Duration(minutes: 3)), skip: skip);
}
