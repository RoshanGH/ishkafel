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

  test('一行放不下就会被自动切开——这是事实，要说出来', () {
    final box = captionBoxOf(
        style: const SubtitleStyle(fontRatio: 0.034),
        text: '这一句话特别特别长长到一屏根本放不下它会被自动切成两屏');
    expect(box.willWrap, isTrue);
  });

  test('放得下就不报', () {
    expect(
      captionBoxOf(style: const SubtitleStyle(), text: '短句').willWrap,
      isFalse,
    );
  });
}
