import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/audio_extractor.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/analysis/scene_detector.dart';
import 'package:ishkafel/core/ffmpeg/ffprobe_service.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/script/script_transcriber.dart';

/// 「上传成片 → ASR → 脚本行（一句一行）」的编排。
/// 假 ffmpeg / 假 ASR，只验编排逻辑与产物清理。
class _FakeAsr implements AsrProvider {
  final List<AsrSentence> sentences;
  final Object? throwing;
  _FakeAsr(this.sentences, {this.throwing});
  @override
  Future<List<AsrSentence>> transcribe(String pcmPath) async {
    if (throwing != null) throw throwing!;
    return sentences;
  }
}

AsrSentence sentence(String text, {int at = 0}) =>
    AsrSentence(startMs: at, endMs: at + 900, text: text);

/// 假 ffprobe 输出：只要够 VideoInfo 解出时长即可
String _probeJson(double seconds) =>
    '{"streams":[{"codec_type":"video","width":1080,"height":1920,'
    '"r_frame_rate":"30/1"}],"format":{"duration":"$seconds","size":"1"}}';

void main() {
  late Directory workDir;
  late File video;

  setUp(() async {
    workDir = await Directory.systemTemp.createTemp('transcriber_test');
    video = File('${workDir.path}/参考片.mp4')..writeAsBytesSync([1, 2, 3]);
  });

  tearDown(() => workDir.delete(recursive: true));

  ScriptTranscriber build({AsrProvider? asr}) => ScriptTranscriber(
        audio: AudioExtractor(run: (exe, args) async {
          await File(args.last).writeAsBytes([0, 0]);
          return ProcessResult(1, 0, '', '');
        }),
        asr: asr ?? _FakeAsr([sentence('第一句'), sentence('第二句', at: 1000)]),
        workDir: workDir,
      );

  test('全链路：ASR 一句一行（脚本行的粒度是一句可配音的话），阶段依次回报', () async {
    final stages = <ScriptTranscribeStage>[];
    final lines =
        await build().extract(video.path, onStage: stages.add);

    expect(lines.map((l) => l.text), ['第一句', '第二句']);
    expect(lines.every((l) => l.type == ScriptLineType.voiced), isTrue);
    expect(
        stages,
        [
          ScriptTranscribeStage.extractingAudio,
          ScriptTranscribeStage.transcribing,
        ],
        reason: '等待要有交代：每个阶段依次回报（未接场景检测时没有切分镜阶段）');
  });

  test('接了场景检测：参考镜按画面切点走，无台词的尾段成画面行', () async {
    final stages = <ScriptTranscribeStage>[];
    final transcriber = ScriptTranscriber(
      audio: AudioExtractor(run: (exe, args) async {
        await File(args.last).writeAsBytes([0, 0]);
        return ProcessResult(1, 0, '', '');
      }),
      asr: _FakeAsr([sentence('第一句'), sentence('第二句', at: 1000)]),
      // 切点 1.0s / 2.5s → 全片三镜：(0,1000) (1000,2500) (2500,8000)
      scenes: SceneDetector(
          run: (exe, args) async =>
              ProcessResult(1, 0, '', 'n:0 pts_time:1.000\nn:1 pts_time:2.500\n')),
      probe: FfprobeService(
          run: (exe, args) async => ProcessResult(1, 0, _probeJson(8.0), '')),
      workDir: workDir,
    );

    final lines = await transcriber.extract(video.path, onStage: stages.add);

    expect(lines.map((l) => l.text), ['第一句', '第二句', '']);
    expect(lines[0].reference!.segments, [(0, 1000)]);
    expect(lines[1].reference!.segments, [(1000, 2500)],
        reason: '第二句的参考镜是完整的一镜，不是被台词边界切出来的碎片');
    expect(lines[2].type, ScriptLineType.visual);
    expect(lines[2].manualMs, 5500, reason: '结尾 5.5 秒没有口播，也得成行');
    expect(stages, contains(ScriptTranscribeStage.cuttingShots));
  });

  test('场景检测出了切点、但探不到时长 → 仍按完整镜头走（末镜到最后一句为止）', () async {
    final transcriber = ScriptTranscriber(
      audio: AudioExtractor(run: (exe, args) async {
        await File(args.last).writeAsBytes([0, 0]);
        return ProcessResult(1, 0, '', '');
      }),
      asr: _FakeAsr([sentence('第一句'), sentence('第二句', at: 1000)]),
      scenes: SceneDetector(
          run: (exe, args) async =>
              ProcessResult(1, 0, '', 'n:0 pts_time:1.000\n')),
      probe: FfprobeService(run: (exe, args) async => ProcessResult(1, 1, '', '坏了')),
      workDir: workDir,
    );

    final lines = await transcriber.extract(video.path);

    expect(lines.map((l) => l.text), ['第一句', '第二句']);
    expect(lines[0].reference!.segments, [(0, 1000)]);
    expect(lines[1].reference!.segments, [(1000, 1900)]);
  });

  test('一句台词都没识别到 → 点名失败，不静默返回空脚本', () async {
    final transcriber = build(asr: _FakeAsr([sentence('  ')]));
    expect(
      () => transcriber.extract(video.path),
      throwsA(isA<ScriptTranscribeException>().having(
          (e) => e.message, 'message', contains('没有识别到任何台词'))),
    );
  });

  test('视频文件不存在 → 直接点名', () async {
    expect(
      () => build().extract('${workDir.path}/不存在.mp4'),
      throwsA(isA<ScriptTranscribeException>()),
    );
  });

  test('ASR 挂了 → 翻译成用户看得懂的话；PCM 中间产物不留', () async {
    final transcriber =
        build(asr: _FakeAsr(const [], throwing: Exception('网络炸了')));
    await expectLater(
      () => transcriber.extract(video.path),
      throwsA(isA<ScriptTranscribeException>()
          .having((e) => e.message, 'message', contains('台词识别失败'))),
    );
    final leftover = workDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.pcm'));
    expect(leftover, isEmpty, reason: '中间产物用完即弃，失败也不留孤儿数据');
  });
}
