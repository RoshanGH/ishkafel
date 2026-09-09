import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/plan_submission.dart';
import 'package:ishkafel/core/ai/frame_check.dart';
import 'package:ishkafel/core/miaoa/miaoa_content_service.dart';
import 'package:ishkafel/core/replacement/picked_material.dart';

/// 取段要靠**素材时长**才算得出来（20 秒素材塞进 0.5 秒坑位，
/// 得知道它是 20 秒才知道要截一段）。而这个数只存在
/// `task.pickedMaterials` 里——界面挑素材时会写，**Agent 提交方案时不写**。
///
/// 结果：Agent 交出来的方案，取段全部退回「整条压缩」，
/// 短镜头照样是十几二十倍快放。修短镜头那一轮做的事，在 Agent 这条路上等于没做。
void main() {
  _burnedTextTests();
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

  test('名字取不到、时长也量不到的，才真的没什么可留', () async {
    final picked = await collectPickedMaterials(
      candidateIds: {11, 12},
      known: const [],
      fetch: (id) async => id == 11 ? null : mat(id),
      probeDurationMs: (id) async => id == 11 ? 0 : 4000,
    );

    expect(picked.map((p) => p.id), [12],
        reason: '11 既没名字也没时长，留一条空记录只会让人以为它是好的');
  });

  /// **不静默降级**：视觉镜头替换靠素材时长算倍速（整条铺满坑位）。量不到
  /// 的那几条算不出该放多快，导进剪映时会被切掉超出坑位的部分——画面缺一截，
  /// 而且哪儿都不报错。必须说出来，不能让人拿到片子才发现。
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


  /// 本地已经有素材文件时，**名字取不到也不该挡住时长**。
  ///
  /// 取段只要时长；名字和描述是给人看的。为了拿个名字每条都跑一次网络往返，
  /// 102 条就是几十秒，而且网一断整批素材就没有时长——取段随之退回快进。
  test('本地有文件时，网络取不到信息也要留住时长', () async {
    final picked = await collectPickedMaterials(
      candidateIds: {11},
      known: const [],
      fetch: (_) async => null, // 网络取不到
      probeDurationMs: (_) async => 20000, // 但本地量得出时长
    );

    expect(picked, hasLength(1),
        reason: '时长量到了就该留下——名字空着不影响取段，没时长才致命');
    expect(picked.single.durationMs, 20000);
  });

}

/// 素材画面上本来就烧着字，是**只有看图才发现得了、而且会毁掉整片**的问题：
/// 换上去之后我们还要再烧一行台词字幕，两层字叠在一起、内容还毫不相干。
///
/// 界面挑素材时会看一眼（`PickedMaterialStore`），Agent 这条路上如果不看，
/// 「所有人能干的事情 Agent 都要能干」就只剩一半——而 Agent 恰恰是那个
/// 一口气挑几十条、人来不及一张张看图的角色。
void _burnedTextTests() {
  CandidateMaterial mat(int id) => CandidateMaterial(
        id: id,
        name: 'm$id',
        sceneDescription: '成人给小孩按摩额头',
        thumbnailUrl: null,
        previewUrl: 'https://c/$id.mov',
        fileKey: 'k$id',
        tags: const [],
      );

  test('提交方案时顺手看一眼素材画面：烧字 + 产品露出品牌', () async {
    final picked = await collectPickedMaterials(
      candidateIds: {11},
      known: const [],
      fetch: (id) async => mat(id),
      probeDurationMs: (_) async => 20000,
      checkFrame: (_) async => const FrameCheck(burnedText: ['冰冰凉凉的好舒服呀']),
    );
    expect(picked.single.burnedText, ['冰冰凉凉的好舒服呀']);
  });

  test('没接检查：记成「没查过」，不许冒充画面没问题', () async {
    final picked = await collectPickedMaterials(
      candidateIds: {11},
      known: const [],
      fetch: (id) async => mat(id),
      probeDurationMs: (_) async => 20000,
    );
    expect(picked.single.burnedTextChecked, isFalse);
  });

  test('看不成也不冒充干净', () async {
    final picked = await collectPickedMaterials(
      candidateIds: {11},
      known: const [],
      fetch: (id) async => mat(id),
      probeDurationMs: (_) async => 20000,
      checkFrame: (_) async => throw StateError('看不了'),
    );
    expect(picked.single.burnedTextChecked, isFalse);
  });

  test('已经看全（三帧）的不重查——一条素材看一次就够', () async {
    final asked = <int>[];
    final picked = await collectPickedMaterials(
      candidateIds: {11},
      known: const [
        PickedMaterial(
            id: 11,
            name: 'm11',
            durationMs: 20000,
            burnedText: [],
            framesSeen: 3),
      ],
      fetch: (id) async => mat(id),
      probeDurationMs: (_) async => 20000,
      checkFrame: (id) async {
        asked.add(id);
        return const FrameCheck();
      },
    );
    expect(asked, isEmpty);
    expect(picked.single.burnedTextChecked, isTrue);
  });

  test('时长有了但还没查过烧字：要补查，不能因为时长齐了就跳过', () async {
    final picked = await collectPickedMaterials(
      candidateIds: {11},
      known: const [PickedMaterial(id: 11, name: 'm11', durationMs: 20000)],
      fetch: (id) async => mat(id),
      probeDurationMs: (_) async => 20000,
      checkFrame: (_) async => const FrameCheck(burnedText: ['已售罄']),
    );
    expect(picked.single.burnedText, ['已售罄']);
    // 补查烧字不该把已经量好的时长弄丢
    expect(picked.single.durationMs, 20000);
  });

  test('产品露出的品牌也一起收下来——同一次调用问的，不额外花钱', () async {
    final picked = await collectPickedMaterials(
      candidateIds: {11},
      known: const [],
      fetch: (id) async => mat(id),
      probeDurationMs: (_) async => 20000,
      checkFrame: (_) async => const FrameCheck(productBrand: '若也 Rove'),
    );
    expect(picked.single.productBrand, '若也 Rove');
    expect(picked.single.hasProduct, isTrue);
  });

  test('点名哪几条烧着字——笼统一句「有素材有问题」等于没说', () {
    expect(
      burnedTextNotice(const [
        PickedMaterial(id: 11, name: 'a', burnedText: ['冰冰凉凉的好舒服呀']),
        PickedMaterial(id: 12, name: 'b', burnedText: []),
      ]),
      allOf(contains('11'), contains('冰冰凉凉的好舒服呀'), isNot(contains('12'))),
    );
    expect(burnedTextNotice(const []), isNull);
    expect(
      burnedTextNotice(const [PickedMaterial(id: 11, name: 'a', burnedText: [])]),
      isNull,
    );
  });
}
