import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import '../analysis/providers.dart';
import '../net/json_poster.dart';

/// 火山大模型录音文件极速版识别（base64 直传，一次请求返回结果）
class VolcanoAsrProvider implements AsrProvider {
  static final _defaultEndpoint = Uri.parse(
      'https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash');

  final String appId;
  final String accessToken;
  final JsonPoster post;
  final int sampleRate;
  final Uri endpoint;
  final String Function() requestIdGenerator;

  VolcanoAsrProvider({
    required this.appId,
    required this.accessToken,
    this.post = httpJsonPoster,
    this.sampleRate = 16000,
    Uri? endpoint,
    String Function()? requestIdGenerator,
  })  : endpoint = endpoint ?? _defaultEndpoint,
        requestIdGenerator = requestIdGenerator ?? _defaultRequestId;

  static String _defaultRequestId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}';

  /// s16le 单声道 PCM 包 44 字节标准 WAV 头
  static Uint8List wrapPcmAsWav(Uint8List pcmBytes, int sampleRate) {
    const channels = 1;
    const bitsPerSample = 16;
    final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
    final header = ByteData(44);
    void writeAscii(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        header.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    writeAscii(0, 'RIFF');
    header.setUint32(4, 36 + pcmBytes.length, Endian.little);
    writeAscii(8, 'WAVE');
    writeAscii(12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little); // PCM
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, channels * bitsPerSample ~/ 8, Endian.little);
    header.setUint16(34, bitsPerSample, Endian.little);
    writeAscii(36, 'data');
    header.setUint32(40, pcmBytes.length, Endian.little);
    return Uint8List.fromList([...header.buffer.asUint8List(), ...pcmBytes]);
  }

  @override
  Future<List<AsrSentence>> transcribe(String pcmPath) async {
    final pcm = await File(pcmPath).readAsBytes();
    final wav = wrapPcmAsWav(pcm, sampleRate);
    final result = await post(
      endpoint,
      {
        'X-Api-App-Key': appId,
        'X-Api-Access-Key': accessToken,
        'X-Api-Resource-Id': 'volc.bigasr.auc_turbo',
        'X-Api-Request-Id': requestIdGenerator(),
        'X-Api-Sequence': '-1',
      },
      jsonEncode({
        'user': {'uid': 'ishkafel'},
        'audio': {'data': base64Encode(wav), 'format': 'wav'},
        'request': {
          'model_name': 'bigmodel',
          'show_utterances': true,
          // 字级输出开关：字段名以文档/实测为准，Task 10 集成冒烟验证 words 非空
          'enable_word': true,
        },
      }),
    );
    final statusCode = result.headers['x-api-status-code'];
    if (result.statusCode != 200 || statusCode != '20000000') {
      final message = result.headers['x-api-message'] ?? result.body;
      throw AiHttpException(
          'ASR 调用失败 [X-Api-Status-Code=$statusCode]：$message',
          statusCode: result.statusCode);
    }
    final json = jsonDecode(result.body) as Map<String, dynamic>;
    final utterances =
        ((json['result'] as Map<String, dynamic>?)?['utterances'] as List?) ??
            const [];
    return List.unmodifiable([
      for (final u in utterances.cast<Map<String, dynamic>>())
        AsrSentence(
          startMs: (u['start_time'] as num).round(),
          endMs: (u['end_time'] as num).round(),
          text: u['text'] as String,
          words: _parseWords(u['words'] as List?),
        ),
    ]);
  }

  /// 解析逐字时间戳，缺失（字段不存在）时返回空列表，不报错
  static List<AsrWord> _parseWords(List? rawWords) {
    if (rawWords == null) return const [];
    return List.unmodifiable([
      for (final w in rawWords.cast<Map<String, dynamic>>())
        AsrWord(
          startMs: (w['start_time'] as num).round(),
          endMs: (w['end_time'] as num).round(),
          text: w['text'] as String,
          confidence: (w['confidence'] as num?)?.toDouble(),
        ),
    ]);
  }
}
