import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/export/export_runner.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

const _bgm = BgmMaterial(id: 9, name: '曲', durationMs: 60000, previewUrl: null);

/// 空白任务铺配乐必须能导出。
///
/// 它没有原片，声音全部来自素材、由 separateMaterial 逐条分离——
/// 「有配乐必须有原片人声轨」这道拦截对它就是「配了乐永远导不出」。
/// 预览侧一直豁免空白任务，导出侧曾经没豁免，两边规则打过架。
void main() {
  test('空白任务 + 配乐 + 无原片人声轨：不再被拦死', () async {
    final work = Directory.systemTemp.createTempSync('ishkafel_blankbgm_w_');
    final out = Directory.systemTemp.createTempSync('ishkafel_blankbgm_o_');
    addTearDown(() {
      if (work.existsSync()) work.deleteSync(recursive: true);
      out.deleteSync(recursive: true);
    });
    final runner = ExportRunner(
      run: (bin, args) async {
        File(args.last).writeAsStringSync('x');
        return ProcessResult(1, 0, '', '');
      },
      workDir: work,
      fetchMaterial: (id) async {
        final f = File('${work.path}/m$id.mp4')..writeAsStringSync('m');
        return f.path;
      },
      // 空白任务的配乐段落靠它拿素材纯人声
      separateMaterial: (path) async {
        final f = File('$path.vocals.wav')..writeAsStringSync('v');
        return f.path;
      },
      probeDurationMs: (_) async => 3000,
    );

    final results = await runner.exportAll(
      sourcePath: null, // 空白任务
      units: const [
        SemanticUnit(index: 0, startMs: 0, endMs: 3000, transcript: 'A'),
      ],
      replacements: [
        UnitReplacement.whole(const [9]),
      ],
      outputDir: out,
      bgm: const BgmPlan([
        BgmSegment(
            startUnit: 0, endUnit: 0, materials: [_bgm], fit: BgmFit.cut),
      ]),
      vocalsPath: null, // 没有原片，自然没有原片人声轨
    );

    expect(results.single.failure, isNot(contains('没有分离出来的纯人声轨')),
        reason: '空白任务被这道拦截挡住就永远导不出配乐版本');
  });

  test('有原片的任务缺人声轨：照旧拦截——两首曲子一起响是静默的错', () async {
    final work = Directory.systemTemp.createTempSync('ishkafel_blankbgm_w2_');
    final out = Directory.systemTemp.createTempSync('ishkafel_blankbgm_o2_');
    addTearDown(() {
      if (work.existsSync()) work.deleteSync(recursive: true);
      out.deleteSync(recursive: true);
    });
    final runner = ExportRunner(
      run: (bin, args) async {
        File(args.last).writeAsStringSync('x');
        return ProcessResult(1, 0, '', '');
      },
      workDir: work,
      fetchMaterial: (id) async => '${work.path}/m$id.mp4',
    );
    final results = await runner.exportAll(
      sourcePath: '/v/src.mp4',
      units: const [
        SemanticUnit(index: 0, startMs: 0, endMs: 3000, transcript: 'A'),
      ],
      replacements: [UnitReplacement.keepOriginal()],
      outputDir: out,
      bgm: const BgmPlan([
        BgmSegment(
            startUnit: 0, endUnit: 0, materials: [_bgm], fit: BgmFit.cut),
      ]),
      vocalsPath: null,
    );
    expect(results.single.failure, contains('没有分离出来的纯人声轨'));
  });
}
