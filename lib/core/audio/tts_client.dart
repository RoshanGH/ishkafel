import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:characters/characters.dart';

import '../ai/ai_usage.dart';
import '../ai/ai_usage_scope.dart';
import '../log/app_log.dart';
import 'tts_protocol.dart';

/// 合成失败。message 已经是可以直接展示给用户的中文。
class TtsException implements Exception {
  final String message;
  const TtsException(this.message);
  @override
  String toString() => message;
}

/// 一次合成的结果
class TtsResult {
  final Uint8List audio;

  /// 字级时间戳（`enable_subtitle` 开启时返回）。对齐到原声要靠它——
  /// 有了每个字落在哪，才能判断是整体偏快还是某处停顿多了。
  final List<TtsWord> words;

  const TtsResult({required this.audio, this.words = const []});
}

class TtsWord {
  final String word;
  final int startMs;
  final int endMs;
  const TtsWord({required this.word, required this.startMs, required this.endMs});
}

/// 豆包语音合成大模型 2.0（WebSocket 双向流）。
///
/// 为什么不是简单的一次 HTTP：2.0 的音色只在这条 WebSocket 路径上提供，
/// HTTP 那条（`/api/v3/tts/unidirectional`）配任何 2.0 音色都会报
/// `resource ID is mismatched with speaker related resource`。
class TtsClient {
  static final _endpoint =
      Uri.parse('wss://openspeech.bytedance.com/api/v3/tts/bidirection');

  /// 预置音色用这个；复刻音色要换成 `seed-icl-2.0`
  static const String presetResource = 'seed-tts-2.0';
  static const String clonedResource = 'seed-icl-2.0';

  final String appId;
  final String accessToken;

  /// 测试注入：把「连一个 WebSocket」这件事替换掉
  final Future<WebSocket> Function(Uri uri, Map<String, dynamic> headers)?
      connect;

  const TtsClient({
    required this.appId,
    required this.accessToken,
    this.connect,
  });

  /// 合成一段语音。
  ///
  /// [instruction] 是**语音指令**（文档里的 `context_texts`）：用一句自然语言
  /// 描述该怎么念，例如「你可以用非常着急、语速很快的语气催促观众吗？」。
  /// 只对预置音色生效——复刻音色暂不支持，传了也会被忽略。
  ///
  /// [speechRate] 取值 [-50, 100]，100 是 2 倍速、-50 是 0.5 倍速。
  Future<TtsResult> synthesize({
    required String text,
    required String speaker,
    String? instruction,
    int? speechRate,
    String resourceId = presetResource,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    // 按合成字符数计费（3 元/万字符，一个汉字算一个字符）。记在请求发出前
    // ——失败重试也是要计费的，火山按送进去的字符算
    AiUsageScope.recordService(
      service: resourceId == clonedResource
          ? SpeechService.voiceClone
          : SpeechService.tts,
      quantity: text.characters.length,
    );

    final headers = <String, dynamic>{
      'X-Api-App-Id': appId,
      'X-Api-Access-Key': accessToken,
      'X-Api-Resource-Id': resourceId,
      'X-Api-App-Key': 'aGjiRDfUWi',
      'X-Api-Connect-Id': _uuid(),
    };

    final socket = await ((connect ?? _defaultConnect)(_endpoint, headers))
        .timeout(timeout,
            onTimeout: () =>
                throw const TtsException('连接语音合成服务超时，请检查网络后重试'));

    final audio = BytesBuilder();
    final words = <TtsWord>[];
    final done = Completer<void>();
    Object? failure;

    final sessionId = _uuid();
    // 注：enable_subtitle 只带回句级文本；词级时间戳这个服务不给
    // （enable_timestamp / additions.with_timestamp 都实测无效），
    // 词级时间戳由 LineVoiceService 用 ASR 对合成音频转写补上
    final audioParams = <String, dynamic>{
      'format': 'mp3',
      'sample_rate': 24000,
      'enable_subtitle': true,
      'speech_rate': ?speechRate,
    };
    final reqParams = <String, dynamic>{
      'speaker': speaker,
      'audio_params': audioParams,
      // 空白指令不传：传一句空的语音指令等于告诉模型「按这个空要求念」，
      // 不如不给
      'context_texts': ?(instruction?.trim().isNotEmpty ?? false)
          ? [instruction!.trim()]
          : null,
    };

    socket.listen(
      (raw) {
        if (raw is! List<int>) return;
        final f = TtsProtocol.parse(Uint8List.fromList(raw));
        switch (f.event) {
          case TtsEvent.connectionStarted:
            _send(socket, TtsEvent.startSession,
                {'user': _user, 'req_params': reqParams}, sessionId);
          case TtsEvent.sessionStarted:
            _send(
                socket,
                TtsEvent.taskRequest,
                {
                  'user': _user,
                  'req_params': {...reqParams, 'text': text},
                },
                sessionId);
            _send(socket, TtsEvent.finishSession, const {}, sessionId);
          case TtsEvent.ttsResponse when f.isAudio:
            audio.add(f.body);
          case TtsEvent.sessionFinished:
            if (!done.isCompleted) done.complete();
          case TtsEvent.connectionFailed:
          case TtsEvent.sessionFailed:
            failure = _reason(f.body);
            if (!done.isCompleted) done.complete();
          default:
            if (f.isAudio) {
              audio.add(f.body);
            } else {
              _collectWords(f.body, words);
            }
        }
      },
      onError: (Object e) {
        failure = e;
        if (!done.isCompleted) done.complete();
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
    );

    _send(socket, TtsEvent.startConnection, const {}, null);

    try {
      await done.future.timeout(timeout,
          onTimeout: () =>
              throw const TtsException('语音合成超时，请稍后重试'));
    } finally {
      unawaited(socket.close());
    }

    if (failure != null) {
      AppLog.warn('语音合成失败：$failure');
      throw TtsException('语音合成失败：$failure');
    }
    final bytes = audio.toBytes();
    if (bytes.isEmpty) {
      // 服务端「正常结束但没给音频」是真实发生过的情形（音色与 resource
      // 不匹配时就是这样）。不当成成功返回一段空音频——那会静默地在成片里
      // 留一段无声。
      throw const TtsException('语音合成没有返回音频，请确认音色是否可用');
    }
    return TtsResult(audio: bytes, words: List.unmodifiable(words));
  }

  static const _user = {'uid': 'ishkafel'};

  void _send(WebSocket socket, int event, Map<String, dynamic> payload,
          String? sessionId) =>
      socket.add(TtsProtocol.frame(
        event: event,
        payload: utf8.encode(jsonEncode(payload)),
        sessionId: sessionId,
      ));

  static Future<WebSocket> _defaultConnect(
          Uri uri, Map<String, dynamic> headers) =>
      WebSocket.connect(uri.toString(), headers: headers);

  /// 从服务端的错误负载里抠出人能看懂的那句
  static String _reason(List<int> body) {
    if (body.isEmpty) return '未提供原因';
    final text = utf8.decode(body, allowMalformed: true);
    try {
      final json = jsonDecode(text);
      if (json is Map) {
        for (final key in const ['error', 'message', 'Message']) {
          if (json[key] is String) return json[key] as String;
        }
      }
    } catch (_) {
      // 不是 JSON 就原样带出去，总比吞掉强
    }
    return text.length > 200 ? '${text.substring(0, 200)}…' : text;
  }

  static void _collectWords(List<int> body, List<TtsWord> out) {
    if (body.isEmpty) return;
    try {
      final json = jsonDecode(utf8.decode(body, allowMalformed: true));
      final words = json is Map ? json['words'] : null;
      if (words is! List) return;
      for (final w in words) {
        if (w is! Map) continue;
        final text = w['word'];
        final start = w['startTime'];
        final end = w['endTime'];
        if (text is! String || start is! num || end is! num) continue;
        out.add(TtsWord(
          word: text,
          startMs: (start * 1000).round(),
          endMs: (end * 1000).round(),
        ));
      }
    } catch (_) {
      // 字幕拿不到不影响音频，静默跳过
    }
  }

  /// 够用的随机 id：只用于关联一次会话，不做安全用途
  static String _uuid() {
    final now = DateTime.now().microsecondsSinceEpoch;
    final rand = Object().hashCode;
    return '$now-$rand';
  }
}
