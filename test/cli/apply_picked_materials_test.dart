import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/plan_submission.dart';
import 'package:ishkafel/core/miaoa/miaoa_content_service.dart';
import 'package:ishkafel/core/replacement/picked_material.dart';

/// 取段要靠**素材时长**才算得出来（20 秒素材塞进 0.5 秒坑位，
/// 得知道它是 20 秒才知道要截一段）。而这个数只存在
/// `task.pickedMaterials` 里——界面挑素材时会写，**Agent 提交方案时不写**。
///
/// 结果：Agent 交出来的方案，取段全部退回「整条压缩」，
/// 短镜头照样是十几二十倍快放。修短镜头那一轮做的事，在 Agent 这条路上等于没做。
void main() {
  CandidateMaterial mat(int id, {String name = 'm'}) => CandidateMaterial(
        id: id,
        name: name,
        sceneDescription: '画面',
        thumbnailUrl: null,
        previewUrl: 'https://c/$id.mov',
        fileKey: 'k$id',
        tags: const [],
      );

  test('提交方案时把用到的素材连同时长一起落下来', () async {
    final picked = await collectPickedMaterials(
      candidateIds: {11, 12},
      known: const [],
      fetch: (id) async => mat(id, name: '素材$id'),
      probeDurationMs: (id) async => id == 11 ? 20000 : 4000,
    );

    expect(picked.map((p) => p.id).toSet(), {11, 12});
    expect(picked.firstWhere((p) => p.id == 11).durationMs, 20000);
    expect(picked.firstWhere((p) => p.id == 11).name, '素材11');
  });

  test('已经存过的不重新取——一条素材量一次就够', () async {
    final asked = <int>[];
    final picked = await collectPickedMaterials(
      candidateIds: {11, 12},
      known: [
        const PickedMaterial(
            id: 11, name: '早就有了', voiceover: '', sceneDescription: '',
            thumbPath: null, durationMs: 20000),
      ],
      fetch: (id) async {
        asked.add(id);
        return mat(id);
      },
      probeDurationMs: (id) async => 4000,
    );

    expect(asked, [12], reason: '11 已经有时长了，不该再量一遍');
    expect(picked.firstWhere((p) => p.id == 11).name, '早就有了');
  });

  test('量不到时长的那条也要留下来，只是没有时长', () async {
    final picked = await collectPickedMaterials(
      candidateIds: {11},
      known: const [],
      fetch: (id) async => mat(id),
      probeDurationMs: (_) async => 0,
    );

    expect(picked, hasLength(1));
    expect(picked.single.durationMs, isNull,
        reason: '存个 0 进去，取段会以为它是 0 秒——那比没有更糟');
  });

  test('取不到素材信息的不拦整批：能拿到的照样落下来', () async {
    final picked = await collectPickedMaterials(
      candidateIds: {11, 12},
      known: const [],
      fetch: (id) async => id == 11 ? null : mat(id),
      probeDurationMs: (_) async => 4000,
    );

    expect(picked.map((p) => p.id), [12]);
  });

  /// **不静默降级**：量不到时长的素材，取段会退回「整条压缩」——短镜头
  /// 又变回十几二十倍快进。这是影响成片的降级，必须说出来，
  /// 不能让人拿到片子才发现有几镜在快放。
  test('有素材量不到时长时，提交要点名说出来', () {
    final notice = trimUnavailableNotice(
      total: 102,
      withDuration: 99,
      shortSlots: 13,
    );

    expect(notice, isNotNull);
    expect(notice!, contains('3'), reason: '要说清有几条没量到');
    expect(notice, contains('快'), reason: '要说清后果是什么，不是只报个数');
  });

  test('全都量到了就不啰嗦', () {
    expect(
        trimUnavailableNotice(total: 102, withDuration: 102, shortSlots: 13),
        isNull);
  });

  test('没有短坑位时也不用提——那些镜头本来就不会变速', () {
    expect(trimUnavailableNotice(total: 102, withDuration: 90, shortSlots: 0),
        isNull);
  });

}
