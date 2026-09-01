import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/delivery_analyzer.dart';
import 'package:ishkafel/core/audio/prosody_profile.dart';
import 'package:ishkafel/core/script/line_delivery_service.dart';
import 'package:ishkafel/core/script/script_doc.dart';

/// **脚本成片也要听一遍参考片这一句是怎么念的。**
///
/// 用户反馈：原片那个人在很激动地争吵，复刻出来平铺直叙。分析这一层
/// （delivery_analyzer）早就有了，替换裂变的换音色一直在用，脚本成片手里
/// 同样握着参考片，只是没接上——这组测试盯的就是「接上了没有」。
///
/// 三条硬要求：没参考片照旧不分析（手写脚本不该白花钱）、分析失败不许挡住
/// 配音但必须说出来、同一句重配不许再花一次钱。
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('delivery'));
  tearDown(() => dir.deleteSync(recursive: true));

  ScriptDoc docWith(ScriptLine line, {String? refVideo = '/ref/a.mp4'}) =>
      ScriptDoc([line], refVideoPath: refVideo);

  ScriptLine lineWith({
    String text = '早就跟你们说了',
    LineRef? reference,
  }) =>
      ScriptLine(
        id: 'l1',
        text: text,
        reference: reference ??
            LineRef(startMs: 1000, endMs: 3000, words: const [
              VoiceWord(text: '早', startMs: 1000, endMs: 1100),
              VoiceWord(text: '就', startMs: 1100, endMs: 1200),
            ]),
      );

  ({LineDeliveryService svc, _FakeAnalyzer analyzer, List<String> slices})
      make() {
    final fake = _FakeAnalyzer();
    final slices = <String>[];
    return (
      svc: LineDeliveryService(
        analyzer: fake,
        slice: (videoPath, startMs, endMs) async {
          slices.add('$videoPath@$startMs~$endMs');
          return const [1, 2, 3];
        },
        cacheDir: dir,
      ),
      analyzer: fake,
      slices: slices,
    );
  }

  group('这一行有没有可听的参考', () {
    test('提取来的行：走文档级参考片 + 行上的区间', () {
      final line = lineWith();
      final req = deliveryRequestOf(docWith(line), line);
      expect(req, isNotNull);
      expect(req!.videoPath, '/ref/a.mp4');
      expect(req.startMs, 1000);
      expect(req.endMs, 3000);
      expect(req.transcript, '早就跟你们说了');
      expect(req.prosody?.hasSignal, isTrue,
          reason: '行上有词级时间戳，客观语速/停顿要一并递给模型当证据');
    });

    test('手写脚本没有参考片，就别分析——白花钱', () {
      final line = ScriptLine(id: 'l1', text: '手写的一句');
      expect(deliveryRequestOf(docWith(line, refVideo: null), line), isNull);
      expect(deliveryRequestOf(docWith(line), line), isNull,
          reason: '行上没有区间，文档级参考片也无从切起');
    });

    test('行上传的是一张图，不去文档级参考片里瞎切', () {
      final line = lineWith(
          reference:
              LineRef(startMs: 0, endMs: 2000, imagePath: '/ref/one.jpg'));
      expect(deliveryRequestOf(docWith(line), line), isNull,
          reason: '图没有声音，那段区间也不是文档级参考片里的坐标');
    });
  });

  group('分析结果要接到配音上', () {
    test('有参考片：切出这一句、听一遍、给出指令', () async {
      final m = make();
      final line = lineWith();
      final d = await m.svc.resolve(deliveryRequestOf(docWith(line), line));
      expect(d.instruction, '用非常激动、带着争辩的语气说这句话');
      expect(m.slices.single, '/ref/a.mp4@1000~3000');
      expect(m.analyzer.calls, 1);
      expect(m.svc.degraded, isEmpty);
    });

    test('没有参考的行：不切片、不分析、不带指令', () async {
      final m = make();
      final line = ScriptLine(id: 'l1', text: '手写的一句');
      final d = await m.svc.resolve(deliveryRequestOf(docWith(line), line));
      expect(d.instruction, isEmpty);
      expect(m.slices, isEmpty);
      expect(m.analyzer.calls, 0);
      expect(m.svc.degraded, isEmpty,
          reason: '本来就没有参考，不算降级——别拿这个吓唬人');
    });
  });

  group('分析失败不许挡住配音，但要说出来', () {
    test('模型挂了：照样返回，指令为空，并点名这一行', () async {
      final svc = LineDeliveryService(
        analyzer: _BrokenAnalyzer(),
        slice: (_, _, _) async => const [1, 2, 3],
        cacheDir: dir,
      );
      final line = lineWith();
      final d = await svc.resolve(deliveryRequestOf(docWith(line), line));
      expect(d.instruction, isEmpty);
      expect(d.degradedReason, isNotNull);
      expect(svc.degraded['l1'], contains('听不了'));
    });

    test('切片失败也一样降级，不抛给配音', () async {
      final svc = LineDeliveryService(
        analyzer: _FakeAnalyzer(),
        slice: (_, _, _) async => throw Exception('ffmpeg 没找到'),
        cacheDir: dir,
      );
      final line = lineWith();
      final d = await svc.resolve(deliveryRequestOf(docWith(line), line));
      expect(d.instruction, isEmpty);
      expect(svc.degraded['l1'], contains('ffmpeg'));
    });
  });

  group('算过一次就别再花钱', () {
    test('同一句重配：直接吃缓存，不再调模型', () async {
      final m = make();
      final line = lineWith();
      final req = deliveryRequestOf(docWith(line), line);
      final first = await m.svc.resolve(req);
      final second = await m.svc.resolve(req);
      expect(second.instruction, first.instruction);
      expect(second.cached, isTrue);
      expect(m.analyzer.calls, 1, reason: '第二次不许再调一次模型');
      expect(m.slices.length, 1, reason: '连切片都不用再切');
    });

    test('换了服务实例也命中——缓存落在盘上', () async {
      final line = lineWith();
      final req = deliveryRequestOf(docWith(line), line);
      await make().svc.resolve(req);
      final again = make();
      final d = await again.svc.resolve(req);
      expect(d.cached, isTrue);
      expect(again.analyzer.calls, 0);
    });

    test('台词改了就重新听——按内容指纹判定，不是按行 id', () async {
      final m = make();
      final a = lineWith();
      await m.svc.resolve(deliveryRequestOf(docWith(a), a));
      final b = lineWith(text: '这句改过了');
      await m.svc.resolve(deliveryRequestOf(docWith(b), b));
      expect(m.analyzer.calls, 2,
          reason: '按行 id 当命中的话，改完台词还会放出上一版的念法');
    });
  });
}

class _FakeAnalyzer implements DeliveryAnalyzer {
  int calls = 0;

  @override
  Future<DeliveryAnalysis> analyze({
    required List<int> audioWav,
    required String transcript,
    ProsodyProfile? prosody,
  }) async {
    calls++;
    return const DeliveryAnalysis(
      description: '语速快，音量大，情绪激动',
      instruction: '用非常激动、带着争辩的语气说这句话',
    );
  }
}

class _BrokenAnalyzer implements DeliveryAnalyzer {
  @override
  Future<DeliveryAnalysis> analyze({
    required List<int> audioWav,
    required String transcript,
    ProsodyProfile? prosody,
  }) async =>
      throw Exception('模型听不了这段音频');
}
