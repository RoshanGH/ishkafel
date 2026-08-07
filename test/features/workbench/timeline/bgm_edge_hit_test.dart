import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/workbench/timeline/bgm_edge_hit.dart';

void main() {
  // 一段配乐画在 x=100~300
  group('段落边界手柄的命中判定', () {
    test('靠近左边缘命中左手柄', () {
      expect(bgmEdgeAt(dx: 102, left: 100, right: 300), BgmEdge.start);
    });

    test('靠近右边缘命中右手柄', () {
      expect(bgmEdgeAt(dx: 297, left: 100, right: 300), BgmEdge.end);
    });

    test('边缘外侧一点也算——手柄要好点，不能只在块体里', () {
      expect(bgmEdgeAt(dx: 97, left: 100, right: 300), BgmEdge.start);
      expect(bgmEdgeAt(dx: 303, left: 100, right: 300), BgmEdge.end);
    });

    test('中间不是手柄——那里是「点开换曲子」', () {
      expect(bgmEdgeAt(dx: 200, left: 100, right: 300), isNull);
    });

    test('离太远不命中', () {
      expect(bgmEdgeAt(dx: 60, left: 100, right: 300), isNull);
      expect(bgmEdgeAt(dx: 340, left: 100, right: 300), isNull);
    });

    test('块体窄到两个手柄要重叠时，左半边算左、右半边算右', () {
      // 只有 10px 宽
      expect(bgmEdgeAt(dx: 101, left: 100, right: 110), BgmEdge.start);
      expect(bgmEdgeAt(dx: 109, left: 100, right: 110), BgmEdge.end);
    });
  });
}
