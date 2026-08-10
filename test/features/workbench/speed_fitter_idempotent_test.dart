import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ffmpeg/rendered_cache.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/features/workbench/speed_fitter.dart';

/// **已经就绪的段落，再 sync 多少次都不该有任何动静。**
///
/// 这条不是洁癖，是防一个真机上出现过的死循环：
///
///   渲完 → notifyListeners → 上层重推轨道 → 又调 sync → 又占位又 notify
///   → 再重推 → ……
///
/// 界面上表现为「正在准备 1 段替换镜头的变速画面」永远转下去，CPU 一直在烧，
/// 而实际上那一段早就渲染好了。
void main() {
  late Directory dir;
  late int ffmpegCalls;

  final units = [
    SemanticUnit(
      index: 0,
      startMs: 0,
      endMs: 4000,
      transcript: '',
      shots: const [
        Shot(startMs: 0, endMs: 2000),
        Shot(startMs: 2000, endMs: 4000),
      ],
    ),
  ];
  final replacements = [
    UnitReplacement.perShot(const {
      1: [77]
    }, previewIds: const {1: 77}),
  ];

  SpeedFitter build() => SpeedFitter(
        cache: RenderedCache(
          dir: dir,
          run: (bin, args) async {
            ffmpegCalls++;
            // 假装 ffmpeg 干完活：把产物写出来
            File(args.last).writeAsStringSync('fake');
            return ProcessResult(0, 0, '', '');
          },
        ),
        probeDurationMs: (_) async => 3000,
      );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ishkafel_fit_');
    ffmpegCalls = 0;
  });

  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> syncOnce(SpeedFitter fitter) => fitter.sync(
        units: units,
        replacements: replacements,
        materialPathOf: (_) => '/candidate.mp4',
      );

  test('第一次 sync 渲染一次，之后再多次都不再跑 ffmpeg', () async {
    final fitter = build();
    await syncOnce(fitter);
    await Future<void>.delayed(Duration.zero);
    expect(ffmpegCalls, 1);
    expect(fitter.fitted, hasLength(1));

    for (var i = 0; i < 5; i++) {
      await syncOnce(fitter);
      await Future<void>.delayed(Duration.zero);
    }
    expect(ffmpegCalls, 1, reason: '已经就绪的段落不该重渲');
  });

  test('就绪之后再 sync 一声不吭——通知一响，上层就会重推轨道，转回来又是一次 sync',
      () async {
    final fitter = build();
    await syncOnce(fitter);
    await Future<void>.delayed(Duration.zero);

    var notifications = 0;
    fitter.addListener(() => notifications++);
    for (var i = 0; i < 5; i++) {
      await syncOnce(fitter);
      await Future<void>.delayed(Duration.zero);
    }
    expect(notifications, 0, reason: '这就是那个死循环的闸门');
  });

  test('已经就绪时 pending 一直是 0，横幅不会闪', () async {
    final fitter = build();
    await syncOnce(fitter);
    await Future<void>.delayed(Duration.zero);

    for (var i = 0; i < 3; i++) {
      final before = fitter.pending;
      await syncOnce(fitter);
      expect(fitter.pending, 0, reason: '占位一闪，界面上就是「正在准备…」一直转');
      expect(before, 0);
    }
  });

  test('候选换了就要重渲——不能因为「就绪过」而一直播旧的那条', () async {
    final fitter = build();
    await syncOnce(fitter);
    await Future<void>.delayed(Duration.zero);
    expect(ffmpegCalls, 1);

    await fitter.sync(
      units: units,
      replacements: replacements,
      materialPathOf: (_) => '/另一条候选.mp4',
    );
    await Future<void>.delayed(Duration.zero);
    expect(ffmpegCalls, 2);
  });

  test('产物被外部删掉时重渲，而不是一直指着一个不存在的文件', () async {
    final fitter = build();
    await syncOnce(fitter);
    await Future<void>.delayed(Duration.zero);
    File(fitter.fitted.values.single).deleteSync();

    await syncOnce(fitter);
    await Future<void>.delayed(Duration.zero);
    expect(ffmpegCalls, 2);
  });
}
