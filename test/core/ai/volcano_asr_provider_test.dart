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

  test('wrapPcmAsWav 头部各字段逐一正确', () {
    final pcm = Uint8List.fromList(List.generate(100, (i) => i));
    final wav = VolcanoAsrProvider.wrapPcmAsWav(pcm, 44100);
    final d = ByteData.sublistView(wav);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(d.getUint32(4, Endian.little), 36 + 100); // RIFF chunk 大小
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(String.fromCharCodes(wav.sublist(12, 16)), 'fmt ');
    expect(d.getUint32(16, Endian.little), 16); // fmt chunk 大小
    expect(d.getUint16(20, Endian.little), 1); // PCM
    expect(d.getUint16(22, Endian.little), 1); // 单声道
    expect(d.getUint32(24, Endian.little), 44100); // 采样率
    expect(d.getUint32(28, Endian.little), 44100 * 2); // byteRate
    expect(d.getUint16(32, Endian.little), 2); // blockAlign
    expect(d.getUint16(34, Endian.little), 16); // 位深
    expect(String.fromCharCodes(wav.sublist(36, 40)), 'data');
    expect(d.getUint32(40, Endian.little), 100); // data 长度
  });

  test('wrapPcmAsWav 拼接后的 PCM 区与原始字节逐字节一致', () {
    final pcm = Uint8List.fromList(List.generate(512, (i) => (i * 7) % 256));
    final wav = VolcanoAsrProvider.wrapPcmAsWav(pcm, 16000);
    expect(wav.length, 44 + 512);
    expect(wav.sublist(44), pcm);
  });

  test('wrapPcmAsWav 空 PCM 只产出 44 字节头，data 长度为 0', () {
    final wav = VolcanoAsrProvider.wrapPcmAsWav(Uint8List(0), 16000);
    expect(wav.length, 44);
    final d = ByteData.sublistView(wav);
    expect(d.getUint32(4, Endian.little), 36);
    expect(d.getUint32(40, Endian.little), 0);
  });

  test('wrapPcmAsWav 不得用展开操作符构造中间 List（大素材下主线程阻塞）', () {
    // 5 分钟 16kHz 单声道 s16le ≈ 9.6MB。展开操作符会先建一个 960 万元素的
    // growable List<int>（每元素 8 字节）再拷贝，实测 75.8ms 阻塞 + 77MB 瞬时
    // 分配；预分配 + setRange 在同规模下是毫秒级。阈值 30ms 留了足够余量。
    final pcm = Uint8List(9600000);
    final sw = Stopwatch()..start();
    final wav = VolcanoAsrProvider.wrapPcmAsWav(pcm, 16000);
    sw.stop();
    expect(wav.length, 44 + pcm.length);
    expect(sw.elapsedMilliseconds, lessThan(30),
        reason: '耗时 ${sw.elapsedMilliseconds}ms，说明仍在构造中间 List');
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
