import 'dart:convert';
import 'dart:typed_data';

/// 豆包语音合成大模型 2.0 的事件号（WebSocket 双向流）
abstract final class TtsEvent {
  static const int startConnection = 1;
  static const int finishConnection = 2;
  static const int connectionStarted = 50;
  static const int connectionFailed = 51;
  static const int connectionFinished = 52;
  static const int startSession = 100;
  static const int finishSession = 102;
  static const int sessionStarted = 150;
  static const int sessionFinished = 152;
  static const int sessionFailed = 153;
  static const int taskRequest = 200;
  static const int ttsSentenceStart = 350;
  static const int ttsSentenceEnd = 351;
  static const int ttsResponse = 352;
}

/// 解析出来的一帧
class TtsFrame {
  /// 消息类型高四位：0x9 = FullServerResponse，0xb = AudioOnlyServer
  final int messageType;
  final int? event;
  final List<int> body;

  const TtsFrame(
      {required this.messageType, required this.event, required this.body});

  bool get isAudio => messageType == 0xb;
}

/// 豆包 TTS 2.0 的二进制分帧协议。
///
/// 单独拆成纯函数是因为：这是整条链路里最容易出错、又最难从现象倒推的一层
/// ——字节序写反、中文按字符数算长度、sessionId 忘了写长度前缀，症状都是
/// 「服务端不回或回一句没头没尾的错误」。放在这里可以完全离线测死。
abstract final class TtsProtocol {
  /// 头部固定 4 字节：
  /// - byte0 高四位协议版本(1)、低四位头长(1，即 4 字节)
  /// - byte1 高四位消息类型、低四位标志位（0x4 = 带事件号）
  /// - byte2 高四位序列化方式(1=JSON)、低四位压缩(0=无)
  /// - byte3 保留
  static Uint8List frame({
    required int event,
    required List<int> payload,
    String? sessionId,
    int messageType = 0x1,
  }) {
    final b = BytesBuilder();
    b.add([0x11, (messageType << 4) | 0x4, 0x10, 0x00]);
    b.add((ByteData(4)..setInt32(0, event)).buffer.asUint8List());
    if (sessionId != null) {
      // sessionId 按 UTF-8 字节数写长度。这里以及下面的负载都必须用字节数，
      // 用字符数在中文上会少算，服务端读到的是截断的内容。
      final sid = utf8.encode(sessionId);
      b.add((ByteData(4)..setUint32(0, sid.length)).buffer.asUint8List());
      b.add(sid);
    }
    b.add((ByteData(4)..setUint32(0, payload.length)).buffer.asUint8List());
    b.add(payload);
    return b.toBytes();
  }

  /// 解析服务端帧。
  ///
  /// 任何长度不足都返回空 body 而不是抛异常：WebSocket 上收到半个包是常态，
  /// 为此崩掉整次合成不值得——上层看到空 body 会继续等下一帧。
  static TtsFrame parse(Uint8List msg) {
    if (msg.length < 4) {
      return const TtsFrame(messageType: 0, event: null, body: []);
    }
    final headerSize = (msg[0] & 0x0f) * 4;
    final messageType = msg[1] >> 4;
    final flags = msg[1] & 0x0f;
    var p = headerSize;

    int? event;
    if (flags & 0x4 != 0) {
      if (msg.length < p + 4) {
        return TtsFrame(messageType: messageType, event: null, body: const []);
      }
      event = ByteData.sublistView(msg, p, p + 4).getInt32(0);
      p += 4;
    }

    // 会话相关的事件才带 sessionId；建连类事件不带
    if (event != null && _hasSessionId(event)) {
      if (msg.length < p + 4) {
        return TtsFrame(messageType: messageType, event: event, body: const []);
      }
      final len = ByteData.sublistView(msg, p, p + 4).getUint32(0);
      p += 4 + len;
    }

    if (msg.length < p + 4) {
      return TtsFrame(messageType: messageType, event: event, body: const []);
    }
    final declared = ByteData.sublistView(msg, p, p + 4).getUint32(0);
    p += 4;
    // 声明长度大于实际剩余时按实际截断，绝不越界读
    final end = (p + declared).clamp(p, msg.length);
    return TtsFrame(
        messageType: messageType, event: event, body: msg.sublist(p, end));
  }

  static bool _hasSessionId(int event) =>
      event == TtsEvent.sessionStarted ||
      event == TtsEvent.sessionFinished ||
      event == TtsEvent.sessionFailed ||
      event == TtsEvent.ttsSentenceStart ||
      event == TtsEvent.ttsSentenceEnd ||
      event == TtsEvent.ttsResponse;

}
