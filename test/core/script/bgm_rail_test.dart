import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/script/bgm_rail.dart';
import 'package:ishkafel/core/script/script_doc.dart';

/// 配乐轨：整片被若干刀切成连续段，铺满全片、无洞无叠。
/// 30 句配 3 首曲子 = 切两刀。
BgmMaterial mat(int id) =>
    BgmMaterial(id: id, name: '曲$id', durationMs: 60000, previewUrl: null);

void main() {
  test('没有配乐时：整片一段「不要配乐」', () {
    final rail = bgmRail(const [], 30);
    expect(rail, hasLength(1));
    expect(rail.single.startLine, 0);
    expect(rail.single.endLine, 29);
    expect(rail.single.silent, isTrue);
  });

  test('落盘段之间的空档补成「不要配乐」的段——轨永远铺满', () {
    final rail = bgmRail([
      ScriptBgmSegment(
          startLine: 5, endLine: 9, material: mat(1), volume: 0.3),
    ], 12);
    expect(rail.map((s) => (s.startLine, s.endLine, s.silent)).toList(), [
      (0, 4, true),
      (5, 9, false),
      (10, 11, true),
    ]);
  });

  test('切一刀：这一句成为新段的开头，先继承上一段的曲子与音量', () {
    var rail = bgmRail([
      ScriptBgmSegment(
          startLine: 0, endLine: 29, material: mat(1), volume: 0.25),
    ], 30);
    rail = splitRailAt(rail, 5);
    rail = splitRailAt(rail, 20);
    expect(rail.map((s) => (s.startLine, s.endLine)).toList(),
        [(0, 4), (5, 19), (20, 29)]);
    expect(rail.every((s) => s.material?.id == 1 && s.volume == 0.25), isTrue,
        reason: '切开只是分段，曲子先继承——多数时候只需再换后面那段');
  });

  test('换曲与音量按段落盘；「不要配乐」的段不落盘', () {
    var rail = splitRailAt(
        bgmRail([
          ScriptBgmSegment(
              startLine: 0, endLine: 9, material: mat(1), volume: 0.3),
        ], 10),
        4);
    rail = [
      rail[0],
      rail[1].copyWith(material: null),
    ];
    final saved = railToSegments(rail);
    expect(saved, hasLength(1));
    expect(saved.single.startLine, 0);
    expect(saved.single.endLine, 3);
  });

  test('拖分界：夹在「上一段留一句、本段留一句」之间', () {
    final rail = splitRailAt(
        bgmRail([
          ScriptBgmSegment(
              startLine: 0, endLine: 9, material: mat(1), volume: 0.3),
        ], 10),
        5);
    expect(moveRailBoundary(rail, 1, 3).map((s) => s.startLine).toList(),
        [0, 3]);
    expect(moveRailBoundary(rail, 1, 0)[1].startLine, 1,
        reason: '上一段至少留一句');
    expect(moveRailBoundary(rail, 1, 99)[1].startLine, 9,
        reason: '本段至少留一句');
  });

  test('删这一刀：并回上一段', () {
    final rail = splitRailAt(
        bgmRail([
          ScriptBgmSegment(
              startLine: 0, endLine: 9, material: mat(1), volume: 0.3),
        ], 10),
        5);
    final merged = mergeRailWithPrev(rail, 1);
    expect(merged, hasLength(1));
    expect(merged.single.endLine, 9);
  });

  group('把中间几句换成另一首（改范围，相邻段让位）', () {
    test('从两段里挖出中间三句：前后各留一段，中间成为新的一段', () {
      // 20 句、两首曲子各管一半；想把第 8~10 句换成第三首
      final rail = bgmRail([
        ScriptBgmSegment(
            startLine: 0,
            endLine: 9,
            material: mat(1), volume: 0.25),
        ScriptBgmSegment(
            startLine: 10,
            endLine: 19,
            material: mat(2), volume: 0.25),
      ], 20);

      final next = setRailRange(rail, 7, 9,
          mat(3), 0.3);

      expect(next.map((s) => (s.startLine, s.endLine, s.material?.name)), [
        (0, 6, '曲1'),
        (7, 9, '曲3'),
        (10, 19, '曲2'),
      ], reason: '中间挖出来独立成段，前后各自缩短，整片仍然连续铺满');
      expect(next[1].volume, 0.3);
    });

    test('新范围跨过整段：被完全盖住的段消失', () {
      final rail = bgmRail([
        ScriptBgmSegment(
            startLine: 0,
            endLine: 4,
            material: mat(1), volume: 0.25),
        ScriptBgmSegment(
            startLine: 5,
            endLine: 9,
            material: mat(2), volume: 0.25),
        ScriptBgmSegment(
            startLine: 10,
            endLine: 19,
            material: mat(3), volume: 0.25),
      ], 20);

      final next = setRailRange(rail, 3, 12,
          mat(9), 0.5);

      expect(next.map((s) => (s.startLine, s.endLine, s.material?.name)), [
        (0, 2, '曲1'),
        (3, 12, '曲9'),
        (13, 19, '曲3'),
      ], reason: '整段被盖住就没了，不留空壳');
    });

    test('铺满全片：只剩一段', () {
      final rail = bgmRail([
        ScriptBgmSegment(
            startLine: 0,
            endLine: 9,
            material: mat(1), volume: 0.25),
        ScriptBgmSegment(
            startLine: 10,
            endLine: 19,
            material: mat(2), volume: 0.25),
      ], 20);
      final next = setRailRange(rail, 0, 19,
          mat(7), 0.4);
      expect(next, hasLength(1));
      expect(next.single.material?.name, '曲7');
    });

    test('范围颠倒时按小的当起点——不许产出一条乱掉的轨', () {
      final rail = bgmRail([
        ScriptBgmSegment(
            startLine: 0,
            endLine: 9,
            material: mat(1), volume: 0.25),
      ], 10);
      final next = setRailRange(rail, 6, 3,
          mat(2), 0.3);
      expect(next.map((s) => (s.startLine, s.endLine)), [(0, 2), (3, 6), (7, 9)]);
    });
  });
}
