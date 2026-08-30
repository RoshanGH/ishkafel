import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/frame_check.dart';
import 'package:ishkafel/core/miaoa/miaoa_content_service.dart';
import 'package:ishkafel/core/replacement/picked_material.dart';
import 'package:ishkafel/features/picking/picked_material_store.dart';

/// 素材画面里烧着的字，是**只有看图才发现得了、而且致命**的一类问题：
/// 拿这条素材去换画面时我们还要再烧一行台词字幕，两套字幕叠在一起、
/// 内容还毫不相干——片子直接废。而它在素材库给的画面描述里一个字都
/// 看不出来（真机：描述写「成人给小孩按摩额头」，画面底部烧着别家
/// 品牌的「冰冰凉凉的好舒服呀」）。
void main() {
  _brandTests();
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('burned'));
  tearDown(() => tmp.deleteSync(recursive: true));

  CandidateMaterial material({String? thumb = 'https://x/1.jpg'}) =>
      CandidateMaterial(
        id: 1,
        name: '素材',
        voiceover: '',
        sceneDescription: '成人给小孩按摩额头',
        thumbnailUrl: thumb,
        previewUrl: null,
        fileKey: null,
        projectId: null,
        tags: const [],
      );

  PickedMaterialStore store(FrameChecker? detector) =>
      PickedMaterialStore(
        dir: tmp,
        fetch: (_) async => [1, 2, 3],
        frameChecker: detector,
      );

  test('看到烧录文字就原样记下来', () async {
    final saved = await store(_Fake(const ['冰冰凉凉的好舒服呀'])).save(material());
    expect(saved.burnedText, ['冰冰凉凉的好舒服呀']);
    expect(saved.hasBurnedText, isTrue);
  });

  test('查过、画面干净：与「没查过」必须分得开', () async {
    final saved = await store(_Fake(const [])).save(material());
    expect(saved.burnedText, isEmpty);
    expect(saved.burnedTextChecked, isTrue);
    expect(saved.hasBurnedText, isFalse);
  });

  test('没配检测器：记为「没查过」，不许冒充干净', () async {
    final saved = await store(null).save(material());
    expect(saved.burnedTextChecked, isFalse);
    expect(saved.hasBurnedText, isFalse);
  });

  test('检测出错也不冒充干净——不知道就是不知道', () async {
    final saved = await store(_Fake(null)).save(material());
    expect(saved.burnedTextChecked, isFalse);
  });

  test('没有首帧图就没法看，记为「没查过」', () async {
    final saved = await store(_Fake(const ['x'])).save(material(thumb: null));
    expect(saved.burnedTextChecked, isFalse);
  });

  test('落地记录能存能读回来', () {
    const m = PickedMaterial(id: 1, name: 'a', burnedText: ['已售罄']);
    final back = PickedMaterial.tryFromJson(m.toJson())!;
    expect(back.burnedText, ['已售罄']);
    expect(back.hasBurnedText, isTrue);
  });
}

class _Fake implements FrameChecker {
  final List<String>? reply;
  _Fake(this.reply);
  @override
  Future<FrameCheck> check(List<String> imagePaths) async => reply == null
      ? (throw StateError('模型没答'))
      : FrameCheck(burnedText: reply!);
}

/// 画面里露出的产品是谁家的——**只有看图才知道**，而它决定这条素材能不能
/// 用在有产品露出的坑位上。台词说「滴露新款消毒液」而画面是若也洗发水
/// 直播间，片子自己打自己的脸（2026-08-28 真机交付过这种片子）。
void _brandTests() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('brand'));
  tearDown(() => tmp.deleteSync(recursive: true));

  CandidateMaterial material() => const CandidateMaterial(
        id: 1,
        name: '素材',
        voiceover: '',
        sceneDescription: '直播间讲解',
        thumbnailUrl: 'https://x/1.jpg',
        previewUrl: null,
        fileKey: null,
        projectId: null,
        tags: [],
      );

  Future<PickedMaterial> save(FrameCheck? reply) => PickedMaterialStore(
        dir: tmp,
        fetch: (_) async => [1, 2, 3],
        frameChecker: reply == null ? null : _FakeChecker(reply),
      ).save(material());

  test('画面里露出的产品品牌记下来', () async {
    final m = await save(const FrameCheck(productBrand: '若也 Rove'));
    expect(m.productBrand, '若也 Rove');
    expect(m.hasProduct, isTrue);
  });

  test('纯场景镜头没有产品：品牌为 null，但仍然算查过', () async {
    final m = await save(const FrameCheck());
    expect(m.productBrand, isNull);
    expect(m.hasProduct, isFalse);
    expect(m.burnedTextChecked, isTrue);
  });

  test('品牌能存能读回来', () {
    const m = PickedMaterial(
        id: 1, name: 'a', burnedText: [], productBrand: '滴露');
    expect(PickedMaterial.tryFromJson(m.toJson())!.productBrand, '滴露');
  });
}

class _FakeChecker implements FrameChecker {
  final FrameCheck reply;
  _FakeChecker(this.reply);
  @override
  Future<FrameCheck> check(List<String> imagePaths) async => reply;
}
