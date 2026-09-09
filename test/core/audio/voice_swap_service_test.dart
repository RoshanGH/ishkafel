import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/audio/delivery_analyzer.dart';
import 'package:ishkafel/core/audio/prosody_profile.dart';
import 'package:ishkafel/core/audio/tts_client.dart';
import 'package:ishkafel/core/audio/voice_plan.dart';
import 'package:ishkafel/core/audio/voice_swap_service.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';

const _voice = VoiceRef(id: 'zh_female_vv_uranus_bigtts', name: '小 V');

class _FakeAnalyzer implements DeliveryAnalyzer {
  final calls = <String>[];
  final String instruction;
  _FakeAnalyzer({this.instruction = '你可以用急迫的语气说吗？'});

  @override
  Future<DeliveryAnalysis> analyze({
    required List<int> audioWav,
    required String transcript,
    ProsodyProfile? prosody,
  }) async {
    calls.add(transcript);
    return DeliveryAnalysis(
        description: '急切', instruction: instruction, prosody: prosody);
  }
}

class _FakeTts implements TtsClient {
  final requests = <({String text, String speaker, String? instruction, int? rate})>[];

  /// 每次合成返回的时长（毫秒），用来驱动对齐逻辑。
  /// 假音频的字节数就写成毫秒数，配合下面的 _fakeMeasure 直接读回来。
  final List<int> durations;
  var _i = 0;

  _FakeTts({this.durations = const [3000]});

  @override
  Future<TtsResult> synthesize({
    required String text,
    required String speaker,
    String? instruction,
    int? speechRate,
    String resourceId = TtsClient.presetResource,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    requests.add((
      text: text,
      speaker: speaker,
      instruction: instruction,
      rate: speechRate
    ));
    final ms = durations[_i.clamp(0, durations.length - 1)];
    _i++;
    // 造一段字节数与时长成正比的假音频，方便下游按字节数判断
    return TtsResult(audio: Uint8List(ms));
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<SemanticUnit> _units() => const [
      SemanticUnit(
        uid: 'u0',
        index: 0,
        startMs: 0,
        endMs: 3000,
        transcript: '第一句台词',
        shots: [Shot(startMs: 0, endMs: 3000)],
      ),
      SemanticUnit(
        uid: 'u1',
        index: 1,
        startMs: 3000,
        endMs: 7000,
        transcript: '第二句台词',
        shots: [Shot(startMs: 3000, endMs: 7000)],
      ),
    ];

const _sentences = [
  AsrSentence(startMs: 0, endMs: 3000, text: '第一句台词', words: [
    AsrWord(startMs: 0, endMs: 500, text: '第'),
    AsrWord(startMs: 500, endMs: 1000, text: '一'),
  ]),
];

/// 假切片器：不碰 ffmpeg，返回一段可辨认的假 WAV
Future<List<int>> _fakeSlicer(int startMs, int endMs) async =>
    Uint8List.fromList(List.filled(16, startMs % 256));

/// 假测量器：假音频的字节数即毫秒数
Future<int> _fakeMeasure(List<int> audio) async => audio.length;

void main() {
  group('只处理被指定了音色的单元', () {
    test('没指定音色的单元完全不碰——原声必须原封不动', () async {
      final tts = _FakeTts();
      final analyzer = _FakeAnalyzer();
      final service = VoiceSwapService(
          tts: tts,
          analyzer: analyzer,
          sliceOriginal: _fakeSlicer,
          measureMs: _fakeMeasure);

      final results = await service.run(
        units: _units(),
        sentences: _sentences,
        plan: VoicePlan.empty.assign(['u1'], _voice),
      );

      expect(results.keys, ['u1']);
      expect(analyzer.calls, ['第二句台词'],
          reason: '给没换音色的单元也去分析一遍，是白花钱');
    });

    test('进度的分母是「要换的那几个」，不是全片单元数', () async {
      final progress = <(int, int)>[];
      final service = VoiceSwapService(
          tts: _FakeTts(),
          analyzer: _FakeAnalyzer(),
          sliceOriginal: _fakeSlicer,
          measureMs: _fakeMeasure);

      await service.run(
        units: _units(),
        sentences: _sentences,
        plan: VoicePlan.empty.assign(['u1'], _voice),
        onProgress: (done, total) => progress.add((done, total)),
      );

      expect(progress.map((p) => p.$2).toSet(), {1},
          reason: '两个单元只换一个，进度却显示 0/2，用户会以为卡在一半不动了');
      expect(progress.last.$1, 1);
    });

    test('一个都没指定时不发任何请求', () async {
      final tts = _FakeTts();
      final service = VoiceSwapService(
          tts: tts,
          analyzer: _FakeAnalyzer(),
          sliceOriginal: _fakeSlicer,
          measureMs: _fakeMeasure);

      final results = await service.run(
        units: _units(),
        sentences: _sentences,
        plan: VoicePlan.empty,
      );

      expect(results, isEmpty);
      expect(tts.requests, isEmpty);
    });
  });

  group('指令与对齐', () {
    test('把分析出的指令带进合成', () async {
      final tts = _FakeTts(durations: const [3000, 3000]);
      final service = VoiceSwapService(
          tts: tts,
          analyzer: _FakeAnalyzer(instruction: '你可以很生气地说吗？'),
          sliceOriginal: _fakeSlicer,
          measureMs: _fakeMeasure);

      await service.run(
        units: _units(),
        sentences: _sentences,
        plan: VoicePlan.empty.assign(['u0'], _voice),
      );

      expect(tts.requests.first.instruction, '你可以很生气地说吗？');
      expect(tts.requests.first.speaker, _voice.id);
    });

    test('首次合成偏离目标时用 speech_rate 重合成一次', () async {
      // 单元 0 时长 3000ms；首次合成 4000ms（慢 33%），应触发重合成
      final tts = _FakeTts(durations: const [4000, 3050]);
      final service = VoiceSwapService(
          tts: tts,
          analyzer: _FakeAnalyzer(),
          sliceOriginal: _fakeSlicer,
          measureMs: _fakeMeasure);

      await service.run(
        units: _units(),
        sentences: _sentences,
        plan: VoicePlan.empty.assign(['u0'], _voice),
      );

      expect(tts.requests, hasLength(2));
      expect(tts.requests.first.rate, isNull, reason: '第一次是探路，不带语速');
      expect(tts.requests.last.rate, greaterThan(0),
          reason: '合成偏慢，第二次要加速');
    });

    test('首次就够接近时不重合成——省一次调用', () async {
      final tts = _FakeTts(durations: const [3020]);
      final service = VoiceSwapService(
          tts: tts,
          analyzer: _FakeAnalyzer(),
          sliceOriginal: _fakeSlicer,
          measureMs: _fakeMeasure);

      await service.run(
        units: _units(),
        sentences: _sentences,
        plan: VoicePlan.empty.assign(['u0'], _voice),
      );

      expect(tts.requests, hasLength(1));
    });
  });

  group('一个单元失败不牵连其余', () {
    test('某个单元合成失败时其余照常产出，并记下失败原因', () async {
      final service = VoiceSwapService(
        tts: _ThrowingOnFirstTts(),
        analyzer: _FakeAnalyzer(),
        sliceOriginal: _fakeSlicer,
        measureMs: _fakeMeasure,
      );

      final results = await service.run(
        units: _units(),
        sentences: _sentences,
        plan: VoicePlan.empty.assign(['u0', 'u1'], _voice),
      );

      expect(results.keys, ['u1'], reason: '第 0 个失败了，第 1 个必须照常出');
      expect(service.failures.keys, ['u0']);
      expect(service.failures['u0'], isNotEmpty);
    });
  });
}

/// 第一次调用抛异常，之后正常
class _ThrowingOnFirstTts implements TtsClient {
  var _calls = 0;

  @override
  Future<TtsResult> synthesize({
    required String text,
    required String speaker,
    String? instruction,
    int? speechRate,
    String resourceId = TtsClient.presetResource,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (_calls++ == 0) throw const TtsException('音色不可用');
    return TtsResult(audio: Uint8List(3000));
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
