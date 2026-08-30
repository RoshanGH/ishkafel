import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/frame_check.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/script/shot_frame_check.dart';

/// 脚本成片挑中的素材也要做画面自查。和替换裂变那边同一套规矩，
/// 单独一个入口——**两条线各写一份的话，迟早只有一份是对的**
/// （取段在这个项目里就是这么栽了三次）。
void main() {
  _copyCompletenessTests();
  LineShot shot(int id, {List<String>? burned, int? frames}) =>
      LineShot(materialId: id, name: 'm$id', burnedText: burned,
          framesSeen: frames);

  test('没查过的都查一遍', () async {
    final out = await checkedShots(
      shots: [shot(1), shot(2)],
      check: (s) async =>
          FrameCheck(burnedText: ['字${s.materialId}'], framesSeen: 3),
    );
    expect(out.map((s) => s.burnedText).toList(), [
      ['字1'],
      ['字2']
    ]);
    expect(out.every((s) => s.framesSeen == 3), isTrue);
  });

  test('已经看全（3 帧）的不重看——一条素材看一次就够', () async {
    final asked = <int>[];
    await checkedShots(
      shots: [shot(1, burned: const [], frames: 3)],
      check: (s) async {
        asked.add(s.materialId);
        return const FrameCheck();
      },
    );
    expect(asked, isEmpty);
  });

  test('只看过一帧的要补看——一帧漏报产品露出', () async {
    final asked = <int>[];
    await checkedShots(
      shots: [shot(1, burned: const [], frames: 1)],
      check: (s) async {
        asked.add(s.materialId);
        return const FrameCheck(productBrand: '滴露', framesSeen: 3);
      },
    );
    expect(asked, [1]);
  });

  test('同一条素材出现在好几句台词上时只查一次', () async {
    final asked = <int>[];
    final out = await checkedShots(
      shots: [shot(7), shot(7), shot(8)],
      check: (s) async {
        asked.add(s.materialId);
        return FrameCheck(productBrand: '牌子${s.materialId}', framesSeen: 3);
      },
    );
    expect(asked, [7, 8], reason: '一条素材配给三句台词，查三次是白花三份钱');
    expect(out.map((s) => s.productBrand).toList(), ['牌子7', '牌子7', '牌子8']);
  });

  test('某一条看不成，不连累其余的——也绝不冒充「画面没问题」', () async {
    final out = await checkedShots(
      shots: [shot(1), shot(2)],
      check: (s) async => s.materialId == 1
          ? throw StateError('看不了')
          : const FrameCheck(burnedText: [], framesSeen: 3),
    );
    expect(out.first.frameChecked, isFalse, reason: '看不成 ≠ 画面干净');
    expect(out.last.frameChecked, isTrue);
  });

  test('参考片截下来的那种（本地源）不用查——那是原片自己的画面', () async {
    final asked = <int>[];
    await checkedShots(
      shots: [LineShot(materialId: -1, name: '参考段', localSource: '/v/a.mp4')],
      check: (s) async {
        asked.add(s.materialId);
        return const FrameCheck();
      },
    );
    expect(asked, isEmpty,
        reason: '本地源是从参考片里截的，画面就是原片的——'
            '报「烧着字」只会天天误报，人很快就不看警告了');
  });
}

/// `LineShot` 有四处**手写逐字段复制**（copyWith、withMeasuredDuration、
/// 画面自查、CLI 提交）。手写复制是丢字段的温床：加一个字段忘了改其中一处，
/// 那条路上这个字段就凭空消失——而且悄无声息。
///
/// 真机上已经因为这类事栽过：改一次时长，取段起点就悬到素材之外去了。
void _copyCompletenessTests() {
  const full = LineShot(
    materialId: 7,
    name: '素材',
    voiceover: '台词',
    sceneDescription: '画面',
    thumbnailUrl: 'https://x/1.jpg',
    fileKey: 'k7',
    durationMs: 20000,
    burnedText: ['已售罄'],
    productBrand: '滴露',
    framesSeen: 3,
    trimStartMs: 500,
    speed: 1.5,
    allocMs: 3000,
    sourceVolume: 0.4,
    startWord: 1,
    endWord: 5,
  );

  /// 两份 json 之间少了哪些键
  Set<String> lost(Map<String, dynamic> before, Map<String, dynamic> after) =>
      before.keys.toSet().difference(after.keys.toSet());

  test('改时长不该弄丢别的字段', () {
    expect(lost(full.toJson(), full.withMeasuredDuration(9000).toJson()),
        isEmpty);
  });

  test('copyWith 不该弄丢别的字段', () {
    expect(lost(full.toJson(), full.copyWith(speed: 2.0).toJson()), isEmpty);
  });

  test('画面自查写回结果时不该弄丢别的字段', () async {
    // 同一条素材，只是还没查过（查过的不会重查，那是对的）
    const unchecked = LineShot(
      materialId: 7,
      name: '素材',
      voiceover: '台词',
      sceneDescription: '画面',
      thumbnailUrl: 'https://x/1.jpg',
      fileKey: 'k7',
      durationMs: 20000,
      trimStartMs: 500,
      speed: 1.5,
      allocMs: 3000,
      sourceVolume: 0.4,
      startWord: 1,
      endWord: 5,
    );
    final out = await checkedShots(
      shots: [unchecked],
      check: (_) async =>
          const FrameCheck(burnedText: ['已售罄'], productBrand: '若也', framesSeen: 3),
    );
    expect(lost(full.toJson(), out.single.toJson()), isEmpty);
    expect(out.single.productBrand, '若也', reason: '新结果要真的写进去');
    expect(out.single.trimStartMs, 500, reason: '取段起点是人调过的，不能丢');
  });
}
