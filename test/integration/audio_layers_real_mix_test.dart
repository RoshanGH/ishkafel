@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/export_commands.dart';

/// 叠加层真的落在它该在的位置上、也真的没有压掉别人——**跑真 ffmpeg 量出来**。
///
/// 为什么必须真跑：这一层出过的两个事故，看命令行参数都是「对的」，
/// 只有把声音合出来量一遍才暴露（2026-09-11 真机）：
///
/// 1. **素材声跑到片头**。滤镜链是「变速 → adelay 挪到位 → atrim 截长度」。
///    `atrim` 会把 `adelay` 垫出来的前导静音整段丢掉，本来靠 muxer 自动补
///    空隙兜着；而链上一旦有 `atempo`（镜头替换必然变速），补空隙就不发生了，
///    于是整层声音落到第 0 秒。
/// 2. **口播被压小一半**。`amix` 默认按路数归一化，静音也算一路，所以从片头
///    起口播就掉 6dB，直到这一层结束才弹回来；而叠加是一层套一层的，
///    有 N 镜保留原声，最前面那段就被压 6×N dB。
///
/// 用户原话：「每一块对应的位置都应该像剪映的时序轴一样，出现在对应的位置上，
/// 不往前补齐任何补位。」
///
/// 跑法：flutter test test/integration/audio_layers_real_mix_test.dart \
///   --tags integration --run-skipped
void main() {
  late Directory work;
  late String ffmpeg;

  setUpAll(() {
    ffmpeg = const ['/opt/homebrew/bin/ffmpeg', '/usr/local/bin/ffmpeg']
        .firstWhere((p) => File(p).existsSync(), orElse: () => 'ffmpeg');
  });
  setUp(() => work = Directory.systemTemp.createTempSync('mixlayer_'));
  tearDown(() => work.deleteSync(recursive: true));

  Future<void> run(List<String> args) async {
    final r = await Process.run(ffmpeg, args);
    expect(r.exitCode, 0, reason: 'ffmpeg 失败：${r.stderr}');
  }

  /// 造一条纯音：[hz] 赫兹、[seconds] 秒的立体声 WAV
  Future<String> tone(String name, int hz, double seconds) async {
    final out = '${work.path}/$name.wav';
    await run([
      '-y', '-v', 'error',
      '-f', 'lavfi', '-i', 'sine=frequency=$hz:duration=$seconds:sample_rate=48000',
      '-ac', '2', '-c:a', 'pcm_s16le', out,
    ]);
    return out;
  }

  /// 量 [path] 的 [fromMs]~[fromMs]+1000ms 这一秒里，[hz] 附近的平均电平（dB）
  Future<double> levelAt(String path, int hz, int fromMs) async {
    final r = await Process.run(ffmpeg, [
      '-ss', '${fromMs / 1000}', '-t', '1',
      '-i', path,
      '-af', 'bandpass=f=$hz:width_type=h:w=60,volumedetect',
      '-f', 'null', '-',
    ]);
    final m = RegExp(r'mean_volume:\s*(-?[0-9.]+) dB').firstMatch('${r.stderr}');
    expect(m, isNotNull, reason: '量不到电平：${r.stderr}');
    return double.parse(m!.group(1)!);
  }

  group('镜头的素材原声：摆在自己的位置上，不压别人', () {
    // 镜头替换一定会变速（候选压进原坑位），所以变速是这条路的常态，
    // 不是边角情形
    for (final speed in [1.0, 2.5]) {
      test('变速 ${speed}× 时，素材声落在 5~7 秒，片头一点都不该有', () async {
        final voice = await tone('voice', 440, 10);
        final material = await tone('material', 1000, 2 * speed);
        final out = '${work.path}/mixed.wav';

        await run(ExportCommands.mixMaterialAudio(
          voice: voice,
          material: material,
          out: out,
          startMs: 5000,
          durationMs: 2000,
          speedFactor: speed,
          volume: 0.5,
        ));

        final atHead = await levelAt(out, 1000, 500);
        final atSlot = await levelAt(out, 1000, 5500);

        expect(atSlot, greaterThan(atHead + 20),
            reason: '素材声该在 5~7 秒（量到 $atSlot dB），'
                '片头只该是底噪（量到 $atHead dB）');
      });

      test('变速 ${speed}× 时，口播从头到尾不被压——各层是相加，不是取平均', () async {
        final voice = await tone('voice', 440, 10);
        final material = await tone('material', 1000, 2 * speed);
        final out = '${work.path}/mixed.wav';

        await run(ExportCommands.mixMaterialAudio(
          voice: voice,
          material: material,
          out: out,
          startMs: 5000,
          durationMs: 2000,
          speedFactor: speed,
          volume: 0.5,
        ));

        final before = await levelAt(voice, 440, 500);
        final after = await levelAt(out, 440, 500);

        expect(after, closeTo(before, 0.5),
            reason: '叠一层素材声之前口播是 $before dB，之后变成 $after dB——'
                '叠加不该动到别人的音量');
      });
    }
  });

  group('配乐：同样摆在自己的位置上，同样不压别人', () {
    test('配乐落在 5~8 秒，片头一点都不该有', () async {
      final voice = await tone('voice', 440, 10);
      final bgm = await tone('bgm', 1000, 4);
      final out = '${work.path}/mixed.wav';

      await run(ExportCommands.mixBgm(
        voice: voice,
        bgm: bgm,
        out: out,
        startMs: 5000,
        durationMs: 3000,
        bgmVolume: 0.5,
      ));

      final atHead = await levelAt(out, 1000, 500);
      final atSlot = await levelAt(out, 1000, 5500);

      expect(atSlot, greaterThan(atHead + 20),
          reason: '配乐该在 5~8 秒（量到 $atSlot dB），'
              '片头只该是底噪（量到 $atHead dB）');
    });

    test('口播不被配乐压小', () async {
      final voice = await tone('voice', 440, 10);
      final bgm = await tone('bgm', 1000, 4);
      final out = '${work.path}/mixed.wav';

      await run(ExportCommands.mixBgm(
        voice: voice,
        bgm: bgm,
        out: out,
        startMs: 5000,
        durationMs: 3000,
        bgmVolume: 0.5,
      ));

      final before = await levelAt(voice, 440, 500);
      final after = await levelAt(out, 440, 500);

      expect(after, closeTo(before, 0.5),
          reason: '叠配乐之前口播是 $before dB，之后变成 $after dB');
    });
  });

  group('叠很多层：越靠前的段落不许被压得越狠', () {
    test('连叠三镜素材原声，片头的口播还是原来那么大', () async {
      final voice = await tone('voice', 440, 20);
      final material = await tone('material', 1000, 1);
      var current = voice;

      for (var i = 0; i < 3; i++) {
        final out = '${work.path}/layer$i.wav';
        await run(ExportCommands.mixMaterialAudio(
          voice: current,
          material: material,
          out: out,
          startMs: 5000 + i * 4000,
          durationMs: 1000,
          speedFactor: 1.0,
          volume: 0.5,
        ));
        current = out;
      }

      final before = await levelAt(voice, 440, 500);
      final after = await levelAt(current, 440, 500);

      expect(after, closeTo(before, 0.5),
          reason: '三层叠完，片头口播从 $before dB 变成 $after dB——'
              '每叠一层压一次，最前面的段落被压得最狠');
    });
  });
}
