import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/audio_track_builder.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';

/// 整体替换的段落铺了配乐时，声音要走**素材的纯人声**。
///
/// 素材自带的背景音留着的话，它和新配乐就是两首曲子一起响——跟原片那一路
/// 是同一个问题，只是音源换成了素材。这个缺陷在替换裂变下一直存在，
/// 只是「整体替换 + 铺配乐」这个组合少有人碰。
void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('mat_sep_');
    File('${temp.path}/material.mp4').writeAsStringSync('m');
    File('${temp.path}/material-人声.wav').writeAsStringSync('v');
  });
  tearDown(() => temp.deleteSync(recursive: true));

  const unit = SemanticUnit(
    index: 0,
    startMs: 0,
    endMs: 4000,
    transcript: '台词',
    shots: [Shot(startMs: 0, endMs: 4000)],
  );

  /// 返回 ffmpeg 每一条命令的输入文件
  Future<List<String>> inputsOf({
    required bool withBgm,
    Future<String?> Function(String)? separate,
  }) async {
    final commands = <List<String>>[];
    final builder = AudioTrackBuilder(
      run: (binary, args) async {
        commands.add(args);
        await File(args.last).writeAsString('out');
        return ProcessResult(1, 0, '', '');
      },
      workDir: Directory('${temp.path}/work'),
      separateMaterial: separate,
      resolveBgm: (m) async => '${temp.path}/bgm.mp3',
    );
    await builder.build(
      sourcePath: null,
      units: const [unit],
      bgm: withBgm
          ? BgmPlan.empty.assign(
              startUnit: 0,
              endUnit: 0,
              rangeMs: 4000,
              materials: [
                const BgmMaterial(
                    id: 1,
                    name: '曲',
                    durationMs: 30000,
                    previewUrl: 'https://example.invalid/1.mp3'),
              ])
          : BgmPlan.empty,
      wholeAudio: {0: '${temp.path}/material.mp4'},
    );
    return [
      for (final args in commands)
        if (args.contains('-i')) args[args.indexOf('-i') + 1],
    ];
  }

  test('铺了配乐 → 用分离出来的纯人声，而不是素材原声', () async {
    final inputs = await inputsOf(
      withBgm: true,
      separate: (path) async => '${temp.path}/material-人声.wav',
    );
    expect(inputs, contains('${temp.path}/material-人声.wav'));
    expect(inputs, isNot(contains('${temp.path}/material.mp4')),
        reason: '带背景音的原声不该再进音轨');
  });

  test('没铺配乐 → 用素材原声，一个字节不改', () async {
    // 分离是有损的（实测残差 -27dB），没换配乐的地方没必要先损一道
    var called = false;
    final inputs = await inputsOf(
      withBgm: false,
      separate: (path) async {
        called = true;
        return '${temp.path}/material-人声.wav';
      },
    );
    expect(called, isFalse, reason: '不铺配乐就不该白白分离一遍');
    expect(inputs, contains('${temp.path}/material.mp4'));
  });

  test('分不了时退回素材原声，不能因此少一段声音', () async {
    final inputs = await inputsOf(withBgm: true, separate: (_) async => null);
    expect(inputs, contains('${temp.path}/material.mp4'));
  });

  test('没接分离器时也照常出片', () async {
    final inputs = await inputsOf(withBgm: true);
    expect(inputs, contains('${temp.path}/material.mp4'));
  });
}
