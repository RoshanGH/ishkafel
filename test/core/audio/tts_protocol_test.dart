import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/tts_protocol.dart';

void main() {
  group('打包请求帧', () {
    test('头部四字节：版本、消息类型、序列化方式', () {
      final f = TtsProtocol.frame(
          event: TtsEvent.startConnection, payload: utf8.encode('{}'));

      expect(f[0], 0x11, reason: '高四位协议版本 1，低四位头长 1（=4 字节）');
      expect(f[1] >> 4, 0x1, reason: 'FullClientRequest');
      expect(f[1] & 0x0f, 0x4, reason: '带事件号的标志位');
      expect(f[2], 0x10, reason: 'JSON 序列化 + 不压缩');
    });

    test('事件号紧跟头部，大端 4 字节', () {
      final f = TtsProtocol.frame(
          event: TtsEvent.startSession, payload: utf8.encode('{}'));

      final event = ByteData.sublistView(f, 4, 8).getInt32(0);
      expect(event, 100);
    });

    test('带 sessionId 时先写它的长度再写内容', () {
      final f = TtsProtocol.frame(
        event: TtsEvent.taskRequest,
        payload: utf8.encode('{}'),
        sessionId: 'abc',
      );

      final len = ByteData.sublistView(f, 8, 12).getUint32(0);
      expect(len, 3);
      expect(utf8.decode(f.sublist(12, 15)), 'abc');
    });

    test('不带 sessionId 时直接跟负载长度', () {
      final f = TtsProtocol.frame(
          event: TtsEvent.startConnection, payload: utf8.encode('{"a":1}'));

      final size = ByteData.sublistView(f, 8, 12).getUint32(0);
      expect(size, 7);
      expect(utf8.decode(f.sublist(12)), '{"a":1}');
    });

    test('中文负载按 UTF-8 计长，不是按字符数', () {
      final payload = utf8.encode('{"text":"再不买"}');
      final f = TtsProtocol.frame(
          event: TtsEvent.taskRequest, payload: payload, sessionId: 's');

      final size = ByteData.sublistView(f, 9 + 4, 9 + 8).getUint32(0);
      expect(size, payload.length);
      expect(size, greaterThan('{"text":"再不买"}'.length),
          reason: '按字符数算会把中文的长度算少，服务端读到的负载是截断的');
    });
  });

  group('解析响应帧', () {
    /// 造一个服务端帧：音频类（AudioOnlyServer）带事件与 sessionId
    Uint8List audioFrame(List<int> audio) {
      final b = BytesBuilder();
      b.add([0x11, (0xb << 4) | 0x4, 0x10, 0x00]);
      b.add((ByteData(4)..setInt32(0, 352)).buffer.asUint8List());
      final sid = utf8.encode('sess');
      b.add((ByteData(4)..setUint32(0, sid.length)).buffer.asUint8List());
      b.add(sid);
      b.add((ByteData(4)..setUint32(0, audio.length)).buffer.asUint8List());
      b.add(audio);
      return b.toBytes();
    }

    test('认出音频帧并取出音频字节', () {
      final parsed = TtsProtocol.parse(audioFrame([1, 2, 3, 4]));

      expect(parsed.isAudio, isTrue);
      expect(parsed.event, 352);
      expect(parsed.body, [1, 2, 3, 4]);
    });

    test('认出会话结束', () {
      final b = BytesBuilder();
      b.add([0x11, (0x9 << 4) | 0x4, 0x10, 0x00]);
      b.add((ByteData(4)..setInt32(0, 152)).buffer.asUint8List());
      final sid = utf8.encode('s');
      b.add((ByteData(4)..setUint32(0, sid.length)).buffer.asUint8List());
      b.add(sid);
      final payload = utf8.encode('{}');
      b.add((ByteData(4)..setUint32(0, payload.length)).buffer.asUint8List());
      b.add(payload);

      final parsed = TtsProtocol.parse(b.toBytes());

      expect(parsed.event, TtsEvent.sessionFinished);
      expect(parsed.isAudio, isFalse);
    });

    test('连接失败帧带得出服务端的原因', () {
      final b = BytesBuilder();
      b.add([0x11, (0x9 << 4) | 0x4, 0x10, 0x00]);
      b.add((ByteData(4)..setInt32(0, 51)).buffer.asUint8List());
      final payload = utf8.encode('{"error":"bad key"}');
      b.add((ByteData(4)..setUint32(0, payload.length)).buffer.asUint8List());
      b.add(payload);

      final parsed = TtsProtocol.parse(b.toBytes());

      expect(parsed.event, TtsEvent.connectionFailed);
      expect(utf8.decode(parsed.body), contains('bad key'),
          reason: '建连失败时不带出原因，用户只会看到「合成失败」四个字');
    });

    test('截断的帧不抛异常——半个包比崩溃好处理', () {
      expect(TtsProtocol.parse(Uint8List.fromList([0x11, 0x14])).body, isEmpty);
      expect(TtsProtocol.parse(Uint8List(0)).body, isEmpty);
    });

    test('负载长度字段大于实际剩余字节时按实际截断，不越界', () {
      final b = BytesBuilder();
      b.add([0x11, (0xb << 4) | 0x4, 0x10, 0x00]);
      b.add((ByteData(4)..setInt32(0, 352)).buffer.asUint8List());
      final sid = utf8.encode('s');
      b.add((ByteData(4)..setUint32(0, sid.length)).buffer.asUint8List());
      b.add(sid);
      b.add((ByteData(4)..setUint32(0, 9999)).buffer.asUint8List());
      b.add([1, 2, 3]);

      expect(TtsProtocol.parse(b.toBytes()).body, [1, 2, 3]);
    });
  });
}
