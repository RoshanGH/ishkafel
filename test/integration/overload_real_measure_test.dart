@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/overload_check.dart';
import 'package:ishkafel/core/export/export_commands.dart';

/// 量电平这条命令**真跑一遍**。
///
/// 它有两处只有真跑才知道：`volumedetect` 的结果打在 info 级上，习惯性的
/// `-v error` 会把它整个压掉（那时解析永远返回 null，于是「从来不报过载」
/// 看起来正好像「一切正常」）；还有 `-nostats` 去掉进度行之后，stderr 是不是
/// 真的干净到能直接解析。
///
/// 跑法：flutter test test/integration/overload_real_measure_test.dart \
///   --tags integration --run-skipped
void main() {
  late Directory work;
  late String ffmpeg;

  setUpAll(() {
    ffmpeg = const ['/opt/homebrew/bin/ffmpeg', '/usr/local/bin/ffmpeg']
        .firstWhere((p) => File(p).existsSync(), orElse: () => 'ffmpeg');
  });
  setUp(() => work = Directory.systemTemp.createTempSync('overload_'));
  tearDown(() => work.deleteSync(recursive: true));

  Future<ProcessResult> run(List<String> args) async {
    final r = await Process.run(ffmpeg, args);
    expect(r.exitCode, 0, reason: 'ffmpeg 失败：${r.stderr}');
    return r;
  }

  /// 造一条 [seconds] 秒、峰值为满刻度 [amplitude] 倍的正弦。
  ///
  /// **直接生成立体声**，不靠 `-ac 2` 从单声道升：升声道那一步会掉 3dB，
  /// 幅度就不是写的那个数了（第一版夹具在这儿栽过，量出来差了 21dB，
  /// 一度让人以为是量电平的命令坏了）。也不用 lavfi 的 `sine`——
  /// 它的输出幅度不是 1.0
  Future<String> tone(String name, double seconds, double amplitude) async {
    final out = '${work.path}/$name.wav';
    final wave = '$amplitude*sin(2*PI*440*t)';
    await run([
      '-y', '-v', 'error',
      '-f', 'lavfi', '-i', 'aevalsrc=$wave|$wave:s=48000:d=$seconds',
      '-c:a', 'pcm_s16le', out,
    ]);
    return out;
  }

  Future<AudioLevels?> measure(String path,
      {int? fromMs, int? durationMs}) async {
    final r = await run(ExportCommands.measureLevels(
        input: path, fromMs: fromMs, durationMs: durationMs));
    return AudioLevels.parse('${r.stderr}');
  }

  test('量得出峰值——-v info 不能省，volumedetect 打在 info 级上', () async {
    final quiet = await tone('quiet', 2, 0.5);

    final levels = await measure(quiet);

    expect(levels, isNotNull, reason: '解析不出来就等于永远不报过载');
    expect(levels!.maxDb, closeTo(-6.0, 0.5));
    expect(levels.clippedSamples, 0);
  });

  test('贴顶的声音量得出贴顶的采样点数', () async {
    final loud = await tone('loud', 2, 1.0);

    final levels = await measure(loud);

    expect(levels!.maxDb, closeTo(0.0, 0.1));
    expect(levels.clippedSamples, greaterThan(0));
  });

  test('只量指定的那一小段——过载要指着说是哪一镜', () async {
    final quiet = await tone('quiet', 4, 0.5);
    final loud = await tone('loud', 1, 1.0);
    final joined = '${work.path}/joined.wav';
    // 前 4 秒安静，第 5 秒贴顶
    await run([
      '-y', '-v', 'error', '-i', quiet, '-i', loud,
      '-filter_complex', '[0:a][1:a]concat=n=2:v=0:a=1[a]',
      '-map', '[a]', '-c:a', 'pcm_s16le', joined,
    ]);

    final head = await measure(joined, fromMs: 0, durationMs: 1000);
    final tail = await measure(joined, fromMs: 4000, durationMs: 1000);

    expect(head!.clippedSamples, 0, reason: '前面那一段不该被算进去');
    expect(tail!.clippedSamples, greaterThan(0));
  });

  test('相加真的会把两条不过载的声音推过头——这正是要报的那件事', () async {
    final a = await tone('a', 2, 0.7);
    final out = '${work.path}/sum.wav';

    await run(ExportCommands.mixMaterialAudio(
      voice: a,
      material: a,
      out: out,
      startMs: 0,
      durationMs: 2000,
      speedFactor: 1.0,
      volume: 0.7,
    ));

    final before = await measure(a);
    final after = await measure(out);

    expect(before!.clippedSamples, 0, reason: '单独一条不过载');
    expect(AudioLevels.addedClipping(base: before, mixed: after), isTrue,
        reason: '0.7 + 0.7×0.7 = 1.19，加起来就过头了');
  });
}
