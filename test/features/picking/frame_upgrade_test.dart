import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/plan_submission.dart';
import 'package:ishkafel/core/ai/frame_check.dart';
import 'package:ishkafel/core/miaoa/miaoa_content_service.dart';
import 'package:ishkafel/core/replacement/picked_material.dart';

/// 两条路看到的帧数不一样：界面挑素材那一刻**只有一张首帧图**（素材本体
/// 还没下），命令行提交方案时素材已经在本地、能抽头中尾三帧。
///
/// 一帧会漏报产品露出（真机：素材 114801 首帧是滴露瓶、中段是微波炉内部）。
/// 所以界面先挑、命令行后提交时，**单帧的结论要能被三帧的结论顶掉**——
/// 不然界面看漏的那一次就被永久固化了。
void main() {
  CandidateMaterial mat(int id) => CandidateMaterial(
        id: id,
        name: 'm$id',
        sceneDescription: '',
        thumbnailUrl: null,
        previewUrl: null,
        fileKey: null,
        projectId: null,
        tags: const [],
      );

  Future<List<PickedMaterial>> collect(List<PickedMaterial> known,
          {required List<int> asked}) =>
      collectPickedMaterials(
        candidateIds: {11},
        known: known,
        fetch: (id) async => mat(id),
        probeDurationMs: (_) async => 20000,
        checkFrame: (id) async {
          asked.add(id);
          return const FrameCheck(productBrand: '滴露', framesSeen: 3);
        },
      );

  test('界面只看过一帧：命令行要拿三帧再看一次', () async {
    final asked = <int>[];
    final out = await collect(const [
      PickedMaterial(
          id: 11, name: 'a', durationMs: 20000, burnedText: [], framesSeen: 1),
    ], asked: asked);
    expect(asked, [11], reason: '单帧的结论不该被当成看全了');
    expect(out.single.productBrand, '滴露');
    expect(out.single.framesSeen, 3);
  });

  test('已经看过三帧的不再重看——一条素材看一次就够', () async {
    final asked = <int>[];
    await collect(const [
      PickedMaterial(
          id: 11, name: 'a', durationMs: 20000, burnedText: [], framesSeen: 3),
    ], asked: asked);
    expect(asked, isEmpty);
  });

  test('老数据没有帧数：当作看过一帧，会被补看', () async {
    final asked = <int>[];
    await collect(const [
      PickedMaterial(id: 11, name: 'a', durationMs: 20000, burnedText: []),
    ], asked: asked);
    expect(asked, [11]);
  });

  test('帧数能存能读回来', () {
    const m = PickedMaterial(id: 1, name: 'a', burnedText: [], framesSeen: 3);
    expect(PickedMaterial.tryFromJson(m.toJson())!.framesSeen, 3);
  });
}
