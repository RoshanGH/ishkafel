import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/export/export_runner.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

BgmMaterial _m(int id, String name) =>
    BgmMaterial(id: id, name: name, durationMs: 30000, previewUrl: 'u$id');

final _a = _m(1, 'A');
final _b = _m(2, 'B');
final _c = _m(3, 'C');

/// 两个单元
List<SemanticUnit> _units() => [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 3000,
        transcript: 'U1',
        shots: [Shot(startMs: 0, endMs: 3000)],
      ),
      SemanticUnit(
        index: 1,
        startMs: 3000,
        endMs: 6000,
        transcript: 'U2',
        shots: [Shot(startMs: 3000, endMs: 6000)],
      ),
    ];

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('ishkafel_rr_'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('总变体数只由画面决定，配乐不做乘法', () async {
    final used = <String>[];
    final runner = ExportRunner(
      run: (binary, args) async {
        await File(args.last).writeAsString('out');
        return ProcessResult(1, 0, '', '');
      },
      workDir: Directory('${temp.path}/work'),
      fetchMaterial: (id) async => '/m/$id.mp4',
      resolveBgm: (m) async {
        used.add(m.name);
        return '/local/${m.id}.mp3';
      },
    );

    final vocals = File('${temp.path}/v.wav')..writeAsStringSync('v');
    final results = await runner.exportAll(
      sourcePath: '/v/a.mp4',
      units: _units(),
      // U1 选了 3 个候选 → 3 条变体
      replacements: [UnitReplacement.whole(const [71, 72, 73])],
      outputDir: Directory('${temp.path}/out'),
      bgm: BgmPlan.empty.assign(
          startUnit: 0, endUnit: 1, materials: [_a, _b, _c], rangeMs: 6000),
      vocalsPath: vocals.path,
    );

    expect(results, hasLength(3), reason: '3 × 1（配乐不参与乘法）');
    expect(used, ['A', 'B', 'C'],
        reason: '三条变体各用一首，用完一轮回到头');
  });

  test('备选比变体多时用不完，不会硬凑变体', () async {
    final used = <String>[];
    final runner = ExportRunner(
      run: (binary, args) async {
        await File(args.last).writeAsString('out');
        return ProcessResult(1, 0, '', '');
      },
      workDir: Directory('${temp.path}/work'),
      fetchMaterial: (id) async => '/m/$id.mp4',
      resolveBgm: (m) async {
        used.add(m.name);
        return '/local/${m.id}.mp3';
      },
    );

    final vocals = File('${temp.path}/v.wav')..writeAsStringSync('v');
    final results = await runner.exportAll(
      sourcePath: '/v/a.mp4',
      units: _units(),
      replacements: const [],
      outputDir: Directory('${temp.path}/out'),
      bgm: BgmPlan.empty.assign(
          startUnit: 0, endUnit: 1, materials: [_a, _b, _c], rangeMs: 6000),
      vocalsPath: vocals.path,
    );

    expect(results, hasLength(1));
    expect(used, ['A'], reason: '只有一条变体，就只用第一首');
  });

  test('镜头替换 + 配乐没备选时，全部变体共用同一条音轨（不白合几遍）', () async {
    var audioBuilds = 0;
    final runner = ExportRunner(
      run: (binary, args) async {
        // 拼接声音那一步的产物叫 mix_voice_<指纹>.wav（先写 .part 再改名）
        if (args.last.contains('mix_voice_')) audioBuilds++;
        await File(args.last).writeAsString('out');
        return ProcessResult(1, 0, '', '');
      },
      workDir: Directory('${temp.path}/work'),
      fetchMaterial: (id) async => '/m/$id.mp4',
      resolveBgm: (m) async => '/local/${m.id}.mp3',
    );

    final vocals = File('${temp.path}/v.wav')..writeAsStringSync('v');
    await runner.exportAll(
      sourcePath: '/v/a.mp4',
      units: _units(),
      // 镜头替换只换画面、变速对齐原坑位，声音一个字节都不变
      replacements: [
        UnitReplacement.perShot(const {
          0: [71, 72, 73]
        })
      ],
      outputDir: Directory('${temp.path}/out'),
      bgm: BgmPlan.empty
          .assign(startUnit: 0, endUnit: 1, materials: [_a], rangeMs: 6000),
      vocalsPath: vocals.path,
    );

    expect(audioBuilds, 1,
        reason: '配乐没有备选、又没有整体替换时，三条变体的声音完全一样，'
            '合一次就够');
  });
}
