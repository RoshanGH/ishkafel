import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/volcano_asr_provider.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/log/app_log.dart';
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
                    {
                      'text': '一',
                      'start_time': 200,
                      'end_time': 400,
                      'confidence': 0
                    },
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
    // 火山真实响应里每个词都带 confidence，值恒为 0（四条真实任务
    // 1703/1703 个词）。「百分百听错」没有哪个 ASR 会这么报，所以 0 就是
    // 「没这个字段」——不在这一层置 null 的话，报告那层会把一列 0.0 当成
    // 事实报出去，而手册教 Agent 拿低置信度认错别字
    expect(sentences.first.words[1].confidence, isNull,
        reason: 'confidence: 0 等于没给');
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

  group('响应体非法时给人话中文错误，不把 TypeError 摊给用户', () {
    late String pcmPath;
    late List<String> logs;

    setUp(() async {
      final tempDir = await Directory.systemTemp.createTemp('ishkafel_asr_bad_');
      addTearDown(() => tempDir.delete(recursive: true));
      pcmPath = '${tempDir.path}/a.pcm';
      await File(pcmPath).writeAsBytes(List.filled(320, 0));
      logs = [];
      final previous = AppLog.sink;
      AppLog.sink = logs.add;
      addTearDown(() => AppLog.sink = previous);
    });

    VolcanoAsrProvider providerReturning(String body) => VolcanoAsrProvider(
          appId: 'app-secret-id',
          accessToken: 'tok-secret-value',
          post: (_, _, _) async => JsonPostResult(
              statusCode: 200,
              headers: const {'x-api-status-code': '20000000'},
              body: body),
        );

    test('响应体不是 JSON（网关 HTML）→ 中文错误，且不回显响应体与凭据', () async {
      final provider =
          providerReturning('<html><body>502 Bad Gateway</body></html>');
      await expectLater(
        provider.transcribe(pcmPath),
        throwsA(isA<AiHttpException>().having(
            (e) => e.message, 'message', contains('不是合法 JSON'))),
      );
      try {
        await provider.transcribe(pcmPath);
      } on AiHttpException catch (e) {
        expect(e.message, isNot(contains('Bad Gateway')));
        expect(e.message, isNot(contains('app-secret-id')));
        expect(e.message, isNot(contains('tok-secret-value')));
        expect(e.message, isNot(contains('TypeError')));
      }
    });

    test('顶层不是 JSON 对象（数组）→ 中文错误', () async {
      await expectLater(
        providerReturning('[1,2,3]').transcribe(pcmPath),
        throwsA(isA<AiHttpException>()
            .having((e) => e.message, 'message', contains('格式异常'))),
      );
    });

    test('utterances 不是数组 → 中文错误', () async {
      final body = jsonEncode({
        'result': {'utterances': 'not-a-list'}
      });
      await expectLater(
        providerReturning(body).transcribe(pcmPath),
        throwsA(isA<AiHttpException>().having(
            (e) => e.message, 'message', contains('utterances'))),
      );
    });

    test('result 不是对象 → 中文错误', () async {
      await expectLater(
        providerReturning(jsonEncode({'result': 'oops'})).transcribe(pcmPath),
        throwsA(isA<AiHttpException>()
            .having((e) => e.message, 'message', contains('格式异常'))),
      );
    });

    test('个别条目非法（非对象/缺字段/类型错）时跳过，合法条目照常返回', () async {
      final body = jsonEncode({
        'result': {
          'utterances': [
            'not-an-object',
            {'text': '缺时间戳'},
            {'start_time': 0, 'end_time': 100}, // 缺 text
            {'start_time': '0', 'end_time': 100, 'text': '时间戳类型错'},
            {'start_time': 200, 'end_time': 900, 'text': '合法句'},
          ]
        }
      });
      final sentences = await providerReturning(body).transcribe(pcmPath);
      expect(sentences.length, 1);
      expect(sentences.single.text, '合法句');
      expect(sentences.single.startMs, 200);
      expect(logs.join(), contains('4'));
    });

    test('全部条目非法 → 中文错误而不是静默返回空', () async {
      final body = jsonEncode({
        'result': {
          'utterances': [
            {'text': '缺时间戳'},
            'not-an-object',
          ]
        }
      });
      await expectLater(
        providerReturning(body).transcribe(pcmPath),
        throwsA(isA<AiHttpException>()
            .having((e) => e.message, 'message', contains('全部'))),
      );
    });

    test('words 畸形不牵连整句：非数组→空，个别字非法→跳过该字', () async {
      final body = jsonEncode({
        'result': {
          'utterances': [
            {
              'start_time': 0,
              'end_time': 500,
              'text': '甲乙',
              'words': 'not-a-list',
            },
            {
              'start_time': 600,
              'end_time': 900,
              'text': '丙丁',
              'words': [
                {'text': '丙', 'start_time': 600, 'end_time': 700},
                'not-an-object',
                {'text': '丁', 'start_time': 700},
                {'text': 42, 'start_time': 700, 'end_time': 900},
                {
                  'text': '丁',
                  'start_time': 700,
                  'end_time': 900,
                  'confidence': 'high',
                },
              ],
            },
          ]
        }
      });
      final sentences = await providerReturning(body).transcribe(pcmPath);
      expect(sentences.length, 2);
      expect(sentences.first.words, isEmpty);
      expect(sentences.last.words.length, 2);
      expect(sentences.last.words.first.text, '丙');
      // confidence 类型错时降级为 null，不牵连该字
      expect(sentences.last.words.last.confidence, isNull);
    });

    test('返回的句子列表不可变，不把可变集合暴露给外部', () async {
      final body = jsonEncode({
        'result': {
          'utterances': [
            {'start_time': 0, 'end_time': 100, 'text': '甲'},
          ]
        }
      });
      final sentences = await providerReturning(body).transcribe(pcmPath);
      expect(
          () => sentences.add(const AsrSentence(
              startMs: 0, endMs: 1, text: 'x')),
          throwsUnsupportedError);
    });
  });
}
