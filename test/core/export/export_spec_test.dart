import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/export_commands.dart';
import 'package:ishkafel/core/export/export_spec.dart';

/// 导出规格：出多大、多清楚。
void main() {
  String vf(List<String> args) => args[args.indexOf('-vf') + 1];
  String crf(List<String> args) => args[args.indexOf('-crf') + 1];

  test('不给规格时保持原样——1080×1920 / CRF 20', () {
    final args = ExportCommands.wholeReplacementVideo(input: 'a.mp4', out: 'o.mp4');
    expect(vf(args), contains('1080:1920'));
    expect(crf(args), '20');
  });

  test('选了 720 就按 720 缩放，且补黑边不拉伸', () {
    final args = ExportCommands.wholeReplacementVideo(
      input: 'a.mp4',
      out: 'o.mp4',
      spec: const ExportSpec(width: 720, height: 1280, crf: 20),
    );
    expect(vf(args), contains('720:1280'));
    expect(vf(args), contains('force_original_aspect_ratio=decrease'),
        reason: '比例不同要补黑边，绝不能拉伸变形');
  });

  test('画质档位落到 CRF 上', () {
    for (final quality in ExportSpec.qualities) {
      final args = ExportCommands.wholeReplacementVideo(
        input: 'a.mp4',
        out: 'o.mp4',
        spec: ExportSpec.standard.copyWith(crf: quality.crf),
      );
      expect(crf(args), '${quality.crf}');
    }
  });

  test('切原片那一路同样吃规格', () {
    final args = ExportCommands.trimOriginalVideo(
      source: 'a.mp4',
      startMs: 0,
      endMs: 1000,
      out: 'o.mp4',
      spec: const ExportSpec(width: 720, height: 1280, crf: 23),
    );
    expect(vf(args), contains('720:1280'));
    expect(crf(args), '23');
  });

  test('存取往返不丢东西', () {
    const spec = ExportSpec(width: 720, height: 1280, crf: 18);
    expect(ExportSpec.fromJson(spec.toJson()), spec);
  });

  test('存坏了退回标准档，不是崩掉', () {
    expect(ExportSpec.fromJson('乱写'), ExportSpec.standard);
    expect(ExportSpec.fromJson(null), ExportSpec.standard);
  });
}
