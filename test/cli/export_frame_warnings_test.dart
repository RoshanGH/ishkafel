import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/export_warnings.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/picked_material.dart';
import 'package:ishkafel/core/subtitle/subtitle_style.dart';

/// 导出是**花钱花时间的最后一步**，出来的就是要交付的片子。
///
/// 界面上的导出确认页会点名有问题的素材，纯命令行这条路一度一声不吭——
/// Agent 查得到（`task --json` 里有），但导出时不提，等于把「要不要用
/// 这条素材」这个判断悄悄跳过了。
///
/// **不拦**：要不要继续是调用方的判断（和「多少条、多大、导到哪」同一档）。
/// 但绝不能不说。
void main() {
  _subtitleClashTests();
  PickedMaterial m(int id, {List<String>? burned, String? brand}) =>
      PickedMaterial(
          id: id, name: 'm$id', burnedText: burned ?? const [],
          productBrand: brand, framesSeen: 3);

  List<SemanticUnit> units(String? brand) => [
        SemanticUnit(
          index: 0,
          startMs: 0,
          endMs: 1000,
          transcript: 'U1',
          shots: [Shot(startMs: 0, endMs: 1000, productBrand: brand)],
        ),
      ];

  test('有烧字的素材要点名', () {
    final lines = exportWarnings(
        picked: [m(1, burned: ['已售罄']), m(2)], units: units(null));
    expect(lines.join(), contains('已售罄'));
    expect(lines.join(), contains('两层字'));
  });

  test('品牌打架要点名', () {
    final lines = exportWarnings(
        picked: [m(1, brand: '滴露'), m(2, brand: '若也')], units: units(null));
    expect(lines.join(), allOf(contains('滴露'), contains('若也')));
  });

  test('候选全跑到别家：拿原片当参照也要说', () {
    final lines =
        exportWarnings(picked: [m(1, brand: '若也')], units: units('滴露'));
    expect(lines.join(), contains('滴露'));
  });

  test('有素材没看成也要说——「不知道」和「没问题」是两回事', () {
    final lines = exportWarnings(
        picked: [const PickedMaterial(id: 1, name: 'a')], units: units(null));
    expect(lines.join(), contains('没看成'));
  });

  test('都干净就不啰嗦——导出前每多一行都是噪音', () {
    expect(exportWarnings(picked: [m(1), m(2)], units: units(null)), isEmpty);
  });

  test('话术要说清这是提醒不是拦截——调用方得知道还能继续', () {
    final lines = exportWarnings(
        picked: [m(1, burned: ['x'])], units: units(null));
    expect(lines.join(), contains('照常导出'));
  });
}

/// 导出那一刻，软件手里同时握着三条信息：
///
/// 1. 这条素材烧着 N 条字（`burnedText`，刚存进去的）
/// 2. 当前字幕预设是 `whiteOutline`
/// 3. 它自己在 `subtitle` 命令的说明里写着「whiteOutline 盖不住烧字」
///
/// **三条凑齐就是「这条会打架」，而它什么都没说**——验收 Agent 的原话：
/// 「不是『导出时忘了拦』，是查过、存了、还写了说明书，就是没在最后一道
/// 门上用。」
void _subtitleClashTests() {
  PickedMaterial burned() => const PickedMaterial(
      id: 1, name: 'm', burnedText: ['已售罄'], framesSeen: 3);

  List<SemanticUnit> units() => const [
        SemanticUnit(
            index: 0, startMs: 0, endMs: 1000, transcript: 'U1', shots: []),
      ];

  test('素材烧着字 + 白描边字幕：要说清这两样会打架', () {
    final lines = exportWarnings(
      picked: [burned()],
      units: units(),
      subtitle: const SubtitleStyle(preset: SubtitlePreset.whiteOutline),
    );
    expect(lines.join(), contains('whiteOutline'));
    expect(lines.join(), anyOf(contains('盖不住'), contains('打架')));
    // 要给出路，不是只报警
    expect(lines.join(), contains('whiteBox'));
  });

  test('已经用能盖住的样式了就不啰嗦这一条', () {
    final lines = exportWarnings(
      picked: [burned()],
      units: units(),
      subtitle: const SubtitleStyle(preset: SubtitlePreset.whiteBox),
    );
    expect(lines.join(), isNot(contains('盖不住')));
    // 但烧字本身还是要报——底条不一定盖得全
    expect(lines.join(), contains('已售罄'));
  });

  test('素材画面干净时，字幕样式是什么都不用提', () {
    final lines = exportWarnings(
      picked: const [PickedMaterial(id: 1, name: 'm', burnedText: [],
          framesSeen: 3)],
      units: units(),
      subtitle: const SubtitleStyle(preset: SubtitlePreset.whiteOutline),
    );
    expect(lines, isEmpty);
  });
}
