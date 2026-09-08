import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/workbench/subtitle_popover_place.dart';

/// 双击字幕块弹出的浮层摆在哪儿。
///
/// 字幕轨只有 22px 高、窄镜头的块可能只有几十像素宽——把块体变成输入框做不出
/// 能用的东西，所以弹一个贴着它的浮层。
///
/// **高度不在这里定死**：估小了会把「加一段」挤到可视区外，点下去落到遮罩上、
/// 浮层直接关掉（写这个功能时真踩到了）。这里只给「贴哪条边、最多多高」。
void main() {
  const screen = Size(1440, 900);
  const width = 340.0;

  test('优先摆在上方，并且**下边贴着块体**——内容变多时往上长', () {
    const anchor = Rect.fromLTWH(600, 500, 80, 22);

    final s = placeSubtitlePopover(
        anchor: anchor, screen: screen, width: width);

    expect(s.isAbove, isTrue);
    expect(s.bottom, screen.height - (anchor.top - 8),
        reason: '用上边定位的话，内容一多浮层就会离开块体往下跑');
  });

  test('横向以块体中心对齐', () {
    const anchor = Rect.fromLTWH(600, 500, 80, 22);

    final s = placeSubtitlePopover(
        anchor: anchor, screen: screen, width: width);

    expect(s.left + width / 2, anchor.center.dx);
  });

  test('块体贴着屏幕左边：夹回屏内，不让半个浮层跑出去', () {
    const anchor = Rect.fromLTWH(4, 500, 30, 22);

    final s = placeSubtitlePopover(
        anchor: anchor, screen: screen, width: width);

    expect(s.left, greaterThanOrEqualTo(8));
  });

  test('块体贴着屏幕右边：同样夹回', () {
    const anchor = Rect.fromLTWH(1420, 500, 20, 22);

    final s = placeSubtitlePopover(
        anchor: anchor, screen: screen, width: width);

    expect(s.left + width, lessThanOrEqualTo(screen.width - 8));
  });

  test('上方余量不如下方时翻到下方，且上边贴着块体', () {
    const anchor = Rect.fromLTWH(600, 40, 80, 22);

    final s = placeSubtitlePopover(
        anchor: anchor, screen: screen, width: width);

    expect(s.isAbove, isFalse);
    expect(s.top, anchor.bottom + 8);
  });

  test('给出的最大高度就是那一侧的余量——超了在浮层里滚，不溢出屏幕', () {
    const anchor = Rect.fromLTWH(600, 500, 80, 22);

    final s = placeSubtitlePopover(
        anchor: anchor, screen: screen, width: width);

    expect(s.maxHeight, 500 - 16);
  });

  test('余量为负也不给负高度', () {
    const anchor = Rect.fromLTWH(600, 0, 80, 4);

    final s = placeSubtitlePopover(
        anchor: anchor, screen: const Size(1440, 6), width: width);

    expect(s.maxHeight, greaterThanOrEqualTo(0));
  });
}
