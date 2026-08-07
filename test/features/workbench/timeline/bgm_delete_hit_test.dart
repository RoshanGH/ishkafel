import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/workbench/timeline/bgm_edge_hit.dart';

void main() {
  // 一段配乐画在 x=100~300、y=40~64（高 24）
  group('段落上的删除按钮', () {
    test('右上角那一小块命中', () {
      expect(
          hitsBgmDelete(
              dx: 292, dy: 46, left: 100, right: 300, top: 40, bottom: 64),
          isTrue);
    });

    test('块体中间不命中——那里是「点开换曲子」', () {
      expect(
          hitsBgmDelete(
              dx: 200, dy: 52, left: 100, right: 300, top: 40, bottom: 64),
          isFalse);
    });

    test('右边缘的拖拽手柄优先，删除按钮往里让', () {
      // 最右侧 6px 是拖拽手柄，删除按钮不该抢它
      expect(
          hitsBgmDelete(
              dx: 299, dy: 46, left: 100, right: 300, top: 40, bottom: 64),
          isFalse,
          reason: '拖边界是高频操作，被删除按钮抢走会误删');
    });

    test('块体窄到放不下按钮时不给——点了必然误伤', () {
      expect(
          hitsBgmDelete(
              dx: 104, dy: 46, left: 100, right: 118, top: 40, bottom: 64),
          isFalse);
    });

    test('纵向超出块体不命中', () {
      expect(
          hitsBgmDelete(
              dx: 292, dy: 80, left: 100, right: 300, top: 40, bottom: 64),
          isFalse);
    });
  });
}
