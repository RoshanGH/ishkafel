import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import '../analysis/providers.dart';
import '../log/app_log.dart';
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
  ///
  /// 一次性预分配 `44 + n` 字节再原地写入：早先用展开操作符
  /// `Uint8List.fromList([...header, ...pcm])`，会先建一个 n 元素的 growable
  /// `List<int>`（每元素 8 字节）再整体拷贝——5 分钟素材实测 75.8ms 主线程阻塞
  /// 加 77MB 瞬时分配，而这段代码跑在导入后的分析流程里，直接卡住 UI。
  static Uint8List wrapPcmAsWav(Uint8List pcmBytes, int sampleRate) {
    const channels = 1;
    const bitsPerSample = 16;
    const headerSize = 44;
    final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
    final wav = Uint8List(headerSize + pcmBytes.length);
    final header = ByteData.sublistView(wav, 0, headerSize);
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
    wav.setRange(headerSize, wav.length, pcmBytes);
    return wav;
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
      // 只用服务端给的 message 头；缺失时不回显响应体——响应体可能整段回显请求
      // 内容（含 base64 音频），拿给用户看既无意义又有泄漏风险，只进日志
      final message = result.headers['x-api-message'];
      if (message == null) {
        AppLog.warn('ASR 调用失败且无 x-api-message，响应体片段：'
            '${_preview(result.body)}');
      }
      throw AiHttpException(
          'ASR 调用失败 [X-Api-Status-Code=$statusCode]：${message ?? '服务端未返回错误说明'}',
          statusCode: result.statusCode);
    }
    return parseResponse(result);
  }

  /// 解析识别响应：任何字段缺失或类型不符都转成人话中文错误。
  ///
  /// 云端响应是不可信输入，早先全是强制 cast——网关返回 HTML 就 FormatException、
  /// 少个 start_time 就「type 'Null' is not a subtype of type 'num'」，这些原文
  /// 会一路冒到用户面前。这里的口径与 [ArkChatClient] 一致：逐级校验，非法条目
  /// 跳过并汇总，异常消息里绝不带响应体原文与凭据。
  static List<AsrSentence> parseResponse(JsonPostResult result) {
    final Object? decoded;
    try {
      decoded = jsonDecode(result.body);
    } on FormatException {
      AppLog.warn('ASR 响应不是合法 JSON，响应体片段：${_preview(result.body)}');
      throw AiHttpException('ASR 响应不是合法 JSON，可能被网关拦截，请稍后重试',
          statusCode: result.statusCode);
    }
    if (decoded is! Map) {
      throw AiHttpException('ASR 响应格式异常：顶层不是 JSON 对象',
          statusCode: result.statusCode);
    }
    final rawResult = decoded['result'];
    if (rawResult == null) return const [];
    if (rawResult is! Map) {
      throw AiHttpException('ASR 响应格式异常：result 不是对象',
          statusCode: result.statusCode);
    }
    final rawUtterances = rawResult['utterances'];
    if (rawUtterances == null) return const [];
    if (rawUtterances is! List) {
      throw AiHttpException('ASR 响应格式异常：utterances 不是数组',
          statusCode: result.statusCode);
    }
    return _parseUtterances(rawUtterances, result.statusCode);
  }

  /// 逐条解析台词，非法条目跳过并汇总；全军覆没则报错，不静默返回空
  static List<AsrSentence> _parseUtterances(List<Object?> raw, int statusCode) {
    final sentences = <AsrSentence>[];
    var skipped = 0;
    for (final item in raw) {
      final sentence = _tryParseSentence(item);
      if (sentence == null) {
        skipped++;
        continue;
      }
      sentences.add(sentence);
    }
    if (skipped > 0) {
      AppLog.warn('ASR 响应中 $skipped 条识别结果字段缺失或类型不符，已跳过');
    }
    if (sentences.isEmpty && skipped > 0) {
      throw AiHttpException('ASR 响应中 $skipped 条识别结果全部格式异常，无法解析出台词',
          statusCode: statusCode);
    }
    return List.unmodifiable(sentences);
  }

  static AsrSentence? _tryParseSentence(Object? raw) {
    if (raw is! Map) return null;
    final startMs = _tryMs(raw['start_time']);
    final endMs = _tryMs(raw['end_time']);
    final text = raw['text'];
    if (startMs == null || endMs == null || text is! String) return null;
    return AsrSentence(
      startMs: startMs,
      endMs: endMs,
      text: text,
      words: _parseWords(raw['words']),
    );
  }

  /// 解析逐字时间戳：字段缺失或畸形都不牵连整句，只丢掉畸形的那个字
  static List<AsrWord> _parseWords(Object? raw) {
    if (raw is! List) return const [];
    final words = <AsrWord>[];
    var skipped = 0;
    for (final item in raw) {
      final word = _tryParseWord(item);
      if (word == null) {
        skipped++;
        continue;
      }
      words.add(word);
    }
    if (skipped > 0) {
      AppLog.warn('ASR 逐字时间戳中 $skipped 个字段缺失或类型不符，已跳过');
    }
    return List.unmodifiable(words);
  }

  static AsrWord? _tryParseWord(Object? raw) {
    if (raw is! Map) return null;
    final startMs = _tryMs(raw['start_time']);
    final endMs = _tryMs(raw['end_time']);
    final text = raw['text'];
    if (startMs == null || endMs == null || text is! String) return null;
    final confidence = raw['confidence'];
    return AsrWord(
      startMs: startMs,
      endMs: endMs,
      text: text,
      // 置信度是可选信息，类型不对就当没有，不因此丢字
      confidence:
          confidence is num && confidence.isFinite ? confidence.toDouble() : null,
    );
  }

  /// 毫秒时间戳：非数值或非有限值一律视为缺失
  static int? _tryMs(Object? raw) =>
      raw is num && raw.isFinite ? raw.round() : null;

  /// 仅用于日志的响应体片段（截断，避免把 base64 音频回显整段写进日志）
  static String _preview(String body) {
    const limit = 120;
    final flat = body.replaceAll(RegExp(r'\s+'), ' ');
    return flat.length <= limit
        ? flat
        : '${flat.substring(0, limit)}…（共 ${body.length} 字符）';
  }
}
