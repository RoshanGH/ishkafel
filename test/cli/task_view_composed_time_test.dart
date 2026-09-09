import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/task_view.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/picked_material.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

/// **Agent 也得知道每一段在成片里落到哪儿。**
///
/// 它拿到的一直只有原片时间，和界面上显示的成片时间对不上——它据此判断
/// 「这一镜够不够铺满这句话」「前后连不连得上」，基准错了判断就错了。
///
/// 但**不许给估算值**：整体替换的那一段长度跟素材走，素材时长不知道就
/// 整块不报并说明原因。报一个差不多的数，它会当真数用。
void main() {
  RenewTask task({
    required List<SemanticUnit> units,
    List<UnitReplacement>? replacements,
    List<PickedMaterial> picked = const [],
  }) =>
      RenewTask(
        id: 't',
        name: 'n',
        sourcePath: '/v/src.mp4',
        status: RenewTaskStatus.ready,
        units: units,
        replacementsByUid:
            RenewTask.byUid(units, replacements ?? const []),
        pickedMaterials: picked,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );

  final units = [
    const SemanticUnit(
        uid: 'u0',
        index: 0,
        startMs: 20000,
        endMs: 30000,
        transcript: '',
        hasSource: false),
    const SemanticUnit(
        uid: 'u1',
        index: 1,
        startMs: 0,
        endMs: 8000,
        transcript: '第一句',
        shots: [
          Shot(startMs: 0, endMs: 3000),
          Shot(startMs: 3000, endMs: 8000),
        ]),
  ];

  test('没有整体替换：每个单元和每一镜都给成片位置', () {
    final j = taskToJson(task(units: units));
    final us = (j['units'] as List).cast<Map<String, dynamic>>();

    expect(us[0]['composedStartMs'], 0, reason: '手加的排在最前，从 0 开始');
    expect(us[1]['composedStartMs'], 10000, reason: '前面占了 10s');

    final shots = (us[1]['shots'] as List).cast<Map<String, dynamic>>();
    expect(shots[1]['composedStartMs'], 13000);
    expect(shots[1]['composedEndMs'], 18000);
  });

  test('原片时间照旧给，但名字说清是原片', () {
    final j = taskToJson(task(units: units));
    final us = (j['units'] as List).cast<Map<String, dynamic>>();

    expect(us[1]['startMs'], 0, reason: '老字段不动，已有调用方还在用');
    expect(us[1]['sourceStartMs'], 0, reason: '新名字把基准写在名字里');
  });

  test('整体替换且知道素材时长：按素材长度算，后面跟着挪', () {
    final j = taskToJson(task(
      units: units,
      replacements: [
        UnitReplacement.whole(const [9], previewId: 9),
        UnitReplacement.keepOriginal(),
      ],
      picked: [
        const PickedMaterial(
            id: 9,
            name: 'm',
            voiceover: '',
            sceneDescription: '',
            durationMs: 4000),
      ],
    ));
    final us = (j['units'] as List).cast<Map<String, dynamic>>();

    expect(us[0]['composedDurationMs'], 4000);
    expect(us[1]['composedStartMs'], 4000, reason: '前面从 10s 缩到 4s');
  });

  test('整体替换但不知道素材时长：整块不报，并说明为什么', () {
    final j = taskToJson(task(
      units: units,
      replacements: [
        UnitReplacement.whole(const [9], previewId: 9),
        UnitReplacement.keepOriginal(),
      ],
    ));
    final us = (j['units'] as List).cast<Map<String, dynamic>>();

    expect(us[0]['composedStartMs'], isNull,
        reason: '报一个差不多的数，Agent 会当真数用来判断铺不铺得满');
    expect(j['composedUnavailable'], isNotNull);
    expect('${j['composedUnavailable']}', contains('U1'),
        reason: '要点名是哪一个单元卡住了，它才知道去补什么');
  });

  test('整体替换的单元：镜头不给成片位置——那些镜头在成片里已经不存在', () {
    final j = taskToJson(task(
      units: [units[1], units[0]],
      replacements: [
        UnitReplacement.whole(const [9], previewId: 9),
        UnitReplacement.keepOriginal(),
      ],
      picked: [
        const PickedMaterial(
            id: 9,
            name: 'm',
            voiceover: '',
            sceneDescription: '',
            durationMs: 4000),
      ],
    ));
    final us = (j['units'] as List).cast<Map<String, dynamic>>();
    final shots = (us[0]['shots'] as List).cast<Map<String, dynamic>>();

    expect(shots.first['composedStartMs'], isNull);
  });
}
