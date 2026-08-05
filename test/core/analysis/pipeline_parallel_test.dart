import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/analysis_pipeline.dart';
import 'package:ishkafel/core/analysis/audio_extractor.dart';
import 'package:ishkafel/core/analysis/boundary_snapper.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/analysis/scene_detector.dart';
import 'package:ishkafel/core/analysis/segmentation_builder.dart';
import 'package:ishkafel/core/analysis/silence_detector.dart';
import 'package:ishkafel/core/audio/vocal_separator.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/video_info.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

/// 三条支线各自阻塞，直到测试放行——这样才能看出它们是同时在跑还是排着队
class _Gates {
  final separate = Completer<void>();
  final scenes = Completer<void>();
  final asr = Completer<void>();
  final started = <String>[];
}

class _Asr implements AsrProvider {
  final _Gates gates;
  _Asr(this.gates);

  @override
  Future<List<AsrSentence>> transcribe(String pcmPath) async {
    gates.started.add('asr');
    await gates.asr.future;
    return const [AsrSentence(startMs: 0, endMs: 1000, text: '一句台词')];
  }
}

class _Splitter implements SemanticSplitter {
  @override
  Future<List<UnitDraft>> split(List<AsrSentence> sentences) async => [
        for (final s in sentences)
          UnitDraft(startMs: s.startMs, endMs: s.endMs, transcript: s.text),
      ];
}

void main() {
  test('分离 / 画面切换 / ASR 三条支线同时开跑，不排队', () async {
    final temp = Directory.systemTemp.createTempSync('ishkafel_par_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final gates = _Gates();

    final pipeline = AnalysisPipeline(
      audio: AudioExtractor(run: (_, args) async {
        await File(args.last).writeAsBytes(Uint8List(16000));
        return ProcessResult(1, 0, '', '');
      }),
      separator: VocalSeparator(
        modelDir: Directory('${temp.path}/models'),
        run: (bin, args) async {
          gates.started.add('separate');
          await gates.separate.future;
          final out = args[args.indexOf('--output_dir') + 1];
          Directory(out).createSync(recursive: true);
          final stem = 'a-${VocalSeparator.modelTag}';
          File('$out/$stem-人声.wav').writeAsStringSync('v');
          File('$out/$stem-背景.wav').writeAsStringSync('b');
          return ProcessResult(1, 0, '', '');
        },
      ),
      silence: const SilenceDetector(),
      scenes: SceneDetector(run: (_, _) async {
        gates.started.add('scenes');
        await gates.scenes.future;
        return ProcessResult(1, 0, '', '');
      }),
      asr: _Asr(gates),
      splitter: _Splitter(),
      builder: const SegmentationBuilder(snapper: BoundarySnapper()),
      repository: FileTaskRepository(temp),
      workDir: Directory('${temp.path}/work'),
      clock: () => DateTime.utc(2026, 8, 5),
    );

    final task = RenewTask(
      id: 'p1',
      name: 'a',
      sourcePath: '/v/a.mp4',
      status: RenewTaskStatus.analyzing,
      createdAt: DateTime.utc(2026, 8, 5),
      updatedAt: DateTime.utc(2026, 8, 5),
      videoInfo: const VideoInfo(
          width: 1080,
          height: 1920,
          duration: Duration(seconds: 4),
          fps: 30,
          fileSizeBytes: 1),
    );
    await FileTaskRepository(temp).save(task);

    final done = pipeline.analyze(task);
    // 让三条支线都有机会启动
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(gates.started, containsAll(<String>['separate', 'scenes', 'asr']),
        reason: '三条支线互不依赖，串行跑它们纯属浪费——实测串行时它们占了 '
            '229 秒里的 120 秒');

    gates.separate.complete();
    gates.scenes.complete();
    gates.asr.complete();
    await done;
  });
}
