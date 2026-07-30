import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/volcano_asr_provider.dart';
import 'package:ishkafel/core/net/json_poster.dart';

void main() {
  test('wrapPcmAsWav 生成合法 44 字节头', () {
    final pcm = Uint8List.fromList([1, 2, 3, 4]);
    final wav = VolcanoAsrProvider.wrapPcmAsWav(pcm, 16000);
    expect(wav.length, 44 + 4);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    final byteData = ByteData.sublistView(wav);
    expect(byteData.getUint32(24, Endian.little), 16000); // 采样率
    expect(byteData.getUint16(22, Endian.little), 1); // 单声道
    expect(byteData.getUint32(40, Endian.little), 4); // data 长度
  });

  test('transcribe 提交 base64 WAV 并解析 utterances 与逐字 words', () async {
    final tempDir = await Directory.systemTemp.createTemp('ishkafel_asr_');
    addTearDown(() => tempDir.delete(recursive: true));
    final pcmPath = '${tempDir.path}/a.pcm';
    await File(pcmPath).writeAsBytes(List.filled(3200, 0));

    late Uri sentUrl;
    late Map<String, String> sentHeaders;
    late Map<String, dynamic> sentBody;
    final provider = VolcanoAsrProvider(
      appId: 'app-1',
      accessToken: 'tok-1',
      requestIdGenerator: () => 'req-1',
      post: (url, headers, body) async {
        sentUrl = url;
        sentHeaders = headers;
        sentBody = jsonDecode(body) as Map<String, dynamic>;
        return JsonPostResult(
          statusCode: 200,
          headers: {'x-api-status-code': '20000000'},
          body: jsonEncode({
            'result': {
              'text': '第一句。第二句。',
              'utterances': [
                {
                  'text': '第一句。',
                  'start_time': 40,
                  'end_time': 1500,
                  'words': [
                    {
                      'text': '第',
                      'start_time': 40,
                      'end_time': 200,
                      'confidence': 0.98
                    },
                    {'text': '一', 'start_time': 200, 'end_time': 400},
                    {
                      'text': '句',
                      'start_time': 400,
                      'end_time': 600,
                      'confidence': 0.91
                    },
                  ],
                },
                {'text': '第二句。', 'start_time': 1600, 'end_time': 3000},
              ]
            }
          }),
        );
      },
    );
    final sentences = await provider.transcribe(pcmPath);
    expect(sentUrl.path, '/api/v3/auc/bigmodel/recognize/flash');
    expect(sentHeaders['X-Api-App-Key'], 'app-1');
    expect(sentHeaders['X-Api-Access-Key'], 'tok-1');
    expect(sentHeaders['X-Api-Resource-Id'], 'volc.bigasr.auc_turbo');
    expect(sentHeaders['X-Api-Request-Id'], 'req-1');
    expect(sentHeaders['X-Api-Sequence'], '-1');
    expect(sentBody['audio']['format'], 'wav');
    expect(sentBody['audio']['data'], isNotEmpty);
    expect(sentBody['request']['model_name'], 'bigmodel');
    expect(sentBody['request']['show_utterances'], true);
    expect(sentBody['request']['enable_word'], true);
    expect(sentences.length, 2);
    expect(sentences.first.text, '第一句。');
    expect(sentences.first.startMs, 40);
    expect(sentences.last.endMs, 3000);
    // 逐字时间戳解析
    expect(sentences.first.words.length, 3);
    expect(sentences.first.words[0].text, '第');
    expect(sentences.first.words[0].startMs, 40);
    expect(sentences.first.words[0].endMs, 200);
    expect(sentences.first.words[0].confidence, 0.98);
    expect(sentences.first.words[1].confidence, isNull);
    expect(sentences.first.words[2].endMs, 600);
    // 第二句无 words 字段 → 空列表，不报错
    expect(sentences.last.words, isEmpty);
  });

  test('X-Api-Status-Code 非成功码抛 AiHttpException', () async {
    final tempDir = await Directory.systemTemp.createTemp('ishkafel_asr2_');
    addTearDown(() => tempDir.delete(recursive: true));
    final pcmPath = '${tempDir.path}/a.pcm';
    await File(pcmPath).writeAsBytes(List.filled(320, 0));
    final provider = VolcanoAsrProvider(
      appId: 'a',
      accessToken: 't',
      post: (_, _, _) async => const JsonPostResult(
          statusCode: 200,
          headers: {'x-api-status-code': '45000001', 'x-api-message': '参数错误'},
          body: '{}'),
    );
    expect(
      () => provider.transcribe(pcmPath),
      throwsA(isA<AiHttpException>()
          .having((e) => e.message, 'message', contains('45000001'))),
    );
  });

  test('utterances 缺失时回退整段文本为单句（0..时长未知取0）或抛错——按实现约定返回空列表', () async {
    final tempDir = await Directory.systemTemp.createTemp('ishkafel_asr3_');
    addTearDown(() => tempDir.delete(recursive: true));
    final pcmPath = '${tempDir.path}/a.pcm';
    await File(pcmPath).writeAsBytes(List.filled(320, 0));
    final provider = VolcanoAsrProvider(
      appId: 'a',
      accessToken: 't',
      post: (_, _, _) async => JsonPostResult(
          statusCode: 200,
          headers: const {'x-api-status-code': '20000000'},
          body: jsonEncode({'result': {'text': '只有整段'}})),
    );
    expect(await provider.transcribe(pcmPath), isEmpty);
  });
}
