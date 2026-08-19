import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/audio_extractor.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/analysis/segmentation_builder.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/script/script_transcriber.dart';

/// 「上传成片 → ASR → 语义断句 → 脚本行」的编排。
/// 假 ffmpeg / 假 ASR / 假断句，只验编排逻辑与产物清理。
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

class _FakeSplitter implements SemanticSplitter {
  final List<UnitDraft>? fixed;
  _FakeSplitter({this.fixed});
  @override
  Future<List<UnitDraft>> split(List<AsrSentence> sentences) async =>
      fixed ??
      [
        for (final s in sentences)
          UnitDraft(startMs: s.startMs, endMs: s.endMs, transcript: s.text),
      ];
}

AsrSentence sentence(String text, {int at = 0}) =>
    AsrSentence(startMs: at, endMs: at + 900, text: text);

void main() {
  late Directory workDir;
  late File video;

  setUp(() async {
    workDir = await Directory.systemTemp.createTemp('transcriber_test');
    video = File('${workDir.path}/参考片.mp4')..writeAsBytesSync([1, 2, 3]);
  });

  tearDown(() => workDir.delete(recursive: true));

  ScriptTranscriber build({AsrProvider? asr, SemanticSplitter? splitter}) =>
      ScriptTranscriber(
        audio: AudioExtractor(run: (exe, args) async {
          await File(args.last).writeAsBytes([0, 0]);
          return ProcessResult(1, 0, '', '');
        }),
        asr: asr ?? _FakeAsr([sentence('第一句'), sentence('第二句', at: 1000)]),
        splitter: splitter ?? _FakeSplitter(),
        workDir: workDir,
      );

  test('全链路：一个断句单元一行，且按顺序回报三个阶段', () async {
    final stages = <ScriptTranscribeStage>[];
    final lines =
        await build().extract(video.path, onStage: stages.add);

    expect(lines.map((l) => l.text), ['第一句', '第二句']);
    expect(lines.every((l) => l.type == ScriptLineType.voiced), isTrue);
    expect(stages, ScriptTranscribeStage.values,
        reason: '等待要有交代：三个阶段依次回报给界面');
  });

  test('一句台词都没识别到 → 点名失败，不静默返回空脚本', () async {
    final transcriber = build(asr: _FakeAsr([sentence('  ')]));
    expect(
      () => transcriber.extract(video.path),
      throwsA(isA<ScriptTranscribeException>().having(
          (e) => e.message, 'message', contains('没有识别到任何台词'))),
    );
  });

  test('断句结果为空时退回「一句一行」，不能空手而归', () async {
    final lines = await build(splitter: _FakeSplitter(fixed: const []))
        .extract(video.path);
    expect(lines.map((l) => l.text), ['第一句', '第二句']);
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
