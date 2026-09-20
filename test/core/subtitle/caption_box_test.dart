import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/subtitle/caption_box.dart';
import 'package:ishkafel/core/subtitle/subtitle_style.dart';

/// 我们这一行字会落在画面的哪个矩形——**纯计算，不用看图**。
///
/// 有了它，「字幕位置合不合适」就从「只能看图」降维成
/// 「两个矩形重不重叠」：素材烧字的矩形到手之后（另一波），一比就知道。
void main() {
  test('矩形按 bottomRatio 和 fontRatio 算出来', () {
    final box = captionBoxOf(
        style: const SubtitleStyle(bottomRatio: 0.22, fontRatio: 0.034),
        text: '一句话');
    expect(box.bottom, closeTo(0.78, 0.001),
        reason: 'bottomRatio 量的是距画面底部，转成从上到下的坐标要用 1 - 0.22');
    expect(box.top, closeTo(0.78 - 0.034, 0.001));
    expect(box.left, lessThan(box.right));
  });

  test('字号调大，一屏放得下的字就变少', () {
    final small = captionBoxOf(
        style: const SubtitleStyle(fontRatio: 0.034), text: '甲');
    final big = captionBoxOf(
        style: const SubtitleStyle(fontRatio: 0.06), text: '甲');
    expect(big.maxCharsPerScreen, lessThan(small.maxCharsPerScreen));
  });

  /// **折行不是「切成两屏先后显示」。** 替换裂变的导出走
  /// `SubtitleRasterizer`，AppKit 按给定宽度折行——超长的那一行是在画面上
  /// 折成两行、同时挂着。说成「自动切成两屏」，人会以为不影响观感
  test('一行放不下就会在画面上折成两行——这是事实，要说出来', () {
    final box = captionBoxOf(
        style: const SubtitleStyle(fontRatio: 0.034),
        text: '这一句话特别特别长长到一屏根本放不下它会在画面上折成两行');
    expect(box.willWrap, isTrue);
  });

  test('放得下就不报', () {
    expect(
      captionBoxOf(style: const SubtitleStyle(), text: '短句').willWrap,
      isFalse,
    );
  });

  /// 真机 U2S3：字号 0.065、一屏 7 字、这一段 10 个字 → 画面上折成两行，
  /// 实际上沿约在 0.37，报的却是 0.435。
  ///
  /// 这个矩形存在的**唯一理由**是「等素材烧字的 bbox 到手就降维成两个矩形
  /// 重不重叠」——高度少算一整行，恰好少在最可能打架的那种情形上
  test('折成两行的，上沿要按两行退，不是永远按一行', () {
    const style = SubtitleStyle(bottomRatio: 0.22, fontRatio: 0.065);
    final box = captionBoxOf(style: style, text: '一二三四五六七八九十');
    expect(box.willWrap, isTrue, reason: '一屏 7 字，这里有 10 个');
    expect(box.top, closeTo(box.bottom - 0.065 * 2, 0.001),
        reason: '少算一整行高度，跟烧字 bbox 比重叠时就会漏判');
  });

  test('一行放得下的，还是按一行算', () {
    const style = SubtitleStyle(bottomRatio: 0.22, fontRatio: 0.065);
    final box = captionBoxOf(style: style, text: '三个字');
    expect(box.top, closeTo(box.bottom - 0.065, 0.001));
  });

  /// 左右留白要跟**真正光栅化时用的**那个数一致，不能各算各的。
  /// 从 `subtitle_rasterizer.dart` 里现抓，不手写一个数——手写的话两边
  /// 各改各的，矩形就会悄悄跟画面上的实际位置差开
  test('左右留白跟真实光栅化用的是同一个数', () {
    final src =
        File('lib/core/subtitle/subtitle_rasterizer.dart').readAsStringSync();
    final m = RegExp(r'Math\.round\(w \* ([\d.]+)\)').firstMatch(src);
    expect(m, isNotNull,
        reason: '光栅化那边的左右留白写法变了，这条测试抓不到，等于空转');
    final margin = double.parse(m!.group(1)!);
    final box = captionBoxOf(style: const SubtitleStyle(), text: '短句');
    expect(box.left, closeTo(margin, 0.0001),
        reason: '报告里的矩形和画面上真烧出来的位置必须是同一件事');
    expect(box.right, closeTo(1 - margin, 0.0001));
  });
}
