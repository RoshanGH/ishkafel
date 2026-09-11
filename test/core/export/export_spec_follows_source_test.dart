import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/export_spec.dart';

/// 剪辑软件里「工程帧率」和「导出帧率」是同一个数。我们把它拆成了两个——
/// 时间线按**原片帧率**数帧，导出帧率却写死 30。原片 60fps 的话，人在时间线
/// 上按 60 数帧、一导出变成 30，中间一句话都没有（2026-09-11 用户提出）。
void main() {
  test('原片是哪一档就取哪一档', () {
    for (final fps in ExportSpec.frameRates) {
      expect(ExportSpec.followingSource(fps.toDouble()).fps, fps);
    }
  });

  test('29.97 取 30，不是 25——四舍五入之后再找档位', () {
    expect(ExportSpec.followingSource(29.97).fps, 30);
    expect(ExportSpec.followingSource(59.94).fps, 60);
    expect(ExportSpec.followingSource(23.976).fps, 24);
  });

  test('不在档位表里的取最接近的一档', () {
    expect(ExportSpec.followingSource(48).fps, 50);
    expect(ExportSpec.followingSource(120).fps, 60);
  });

  test('读不出帧率（空白任务没有原片）时退回标准档', () {
    expect(ExportSpec.followingSource(0).fps, ExportSpec.standard.fps);
    expect(ExportSpec.followingSource(-1).fps, ExportSpec.standard.fps);
  });

  test('只改帧率，别的规格一个都不动', () {
    final spec = ExportSpec.followingSource(60);
    expect(spec.shortSide, ExportSpec.standard.shortSide);
    expect(spec.codec, ExportSpec.standard.codec);
    expect(spec.format, ExportSpec.standard.format);
  });
}
