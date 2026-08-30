import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/taggers.dart';

/// 原片的视觉镜头打标时也问一句「画面里露的是谁家产品」。
///
/// 为什么要在这儿问：候选素材之间品牌打架能自己看出来，但**「候选和本片
/// 对不对得上」要有个参照**——一条片子全用了别家的素材，候选之间毫无冲突，
/// 可它整条都错了。这个参照只能来自原片自己。
///
/// 而且这一句是**白问的**：视觉打标本来就在看图、本来就是一次调用。
void main() {
  test('打标提示词要问产品露出的品牌', () {
    final prompt = buildShotUnderstandingPrompt(3, const [], null);
    expect(prompt, contains('productBrand'));
    // 认不出来要给 null——瞎猜一个牌子比不知道更糟
    expect(prompt, contains('null'));
  });

  test('打标提示词仍然问烧录文字——别改一件事碰坏另一件', () {
    final prompt = buildShotUnderstandingPrompt(3, const [], null);
    expect(prompt, contains('burnedText'));
  });
}
