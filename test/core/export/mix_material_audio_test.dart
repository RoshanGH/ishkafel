import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/export_commands.dart';

/// 视觉镜头替换时把**候选素材自己的声音**叠回成片。
///
/// 画面那边是「变速填满原坑位」（`setpts=PTS/factor`）。声音必须走同样的
/// 倍率，否则叠上去会越走越偏——画面在喷第二下了，声音还停在第一下。
void main() {
  List<String> cmd({
    double speed = 1.0,
    int? trimStartMs,
    double volume = 0.25,
  }) =>
      ExportCommands.mixMaterialAudio(
        voice: '/w/voice.wav',
        material: '/w/mat.mp4',
        out: '/w/out.wav',
        startMs: 5000,
        durationMs: 2000,
        speedFactor: speed,
        trimStartMs: trimStartMs,
        volume: volume,
      );

  String filterOf(List<String> args) =>
      args[args.indexOf('-filter_complex') + 1];

  test('叠在成片的这一段上，按给定音量压低', () {
    final f = filterOf(cmd(volume: 0.4));

    expect(f, contains('volume=0.4'));
    expect(f, contains('adelay=5000|5000'), reason: '要落在成片的 5 秒处');
    expect(f, contains('amix=inputs=2'), reason: '和已有的声音同时响，不是替换');
  });

  test('变速时声音跟着变速——不然画面和声音会越走越偏', () {
    final f = filterOf(cmd(speed: 1.5));

    expect(f, contains('atempo=1.5'));
  });

  test('几乎不变速时不插 atempo，白走一道只会掉音质', () {
    expect(filterOf(cmd(speed: 1.0)), isNot(contains('atempo')));
  });

  test('倍率超出单节范围时拆成连乘', () {
    final f = filterOf(cmd(speed: 2.9));

    expect('atempo'.allMatches(f).length, greaterThan(1));
  });

  test('从素材的某一秒起截时，-ss 摆在 -i 前面（放后面要白解一大段）', () {
    final args = cmd(trimStartMs: 3000);
    final ss = args.indexOf('-ss');
    final firstInput = args.indexOf('-i');

    expect(ss, greaterThanOrEqualTo(0));
    expect(ss, greaterThan(firstInput),
        reason: '第一个 -i 是人声轨，-ss 要贴在素材那个 -i 前面');
    expect(args[ss + 1], '3.000');
    expect(args[ss + 2], '-i');
    expect(args[ss + 3], '/w/mat.mp4');
  });

  test('没给起点就不带 -ss', () {
    expect(cmd().contains('-ss'), isFalse);
  });

  test('声音只取这一段那么长，不许溢到后面的镜头上', () {
    final f = filterOf(cmd());

    expect(f, contains('atrim=0:7.000'),
        reason: '5 秒处开始、放 2 秒，到 7 秒截断');
  });
}
