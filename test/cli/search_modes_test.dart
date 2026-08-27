import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/search_modes.dart';

/// Agent 能用哪几种检索方式。
///
/// 用户的要求：**让 Agent 使用所有软件可以使用的功能**。
/// 审计下来软件有 5 种检索，Agent 只能用 2 种——尤其缺的是**以图搜图**，
/// 而复刻场景最该用它：手里就有参考镜的画面，直接拿去找像的最准。
void main() {
  test('五种方式都认得', () {
    for (final w in const ['tags', 'content', 'image', 'voiceover', 'name']) {
      expect(SearchMode.parse(w), isNotNull, reason: '缺 $w');
    }
  });

  test('认不出的返回 null，不默默退回某一种', () {
    expect(SearchMode.parse('随便写'), isNull);
    // 静默退回会让 Agent 以为自己搜的是 A、实际搜的是 B
  });

  test('每种都说得出它靠什么找、什么时候用', () {
    for (final m in SearchMode.values) {
      expect(m.label, isNotEmpty);
      expect(m.whenToUse, isNotEmpty, reason: '${m.wire} 没说清什么时候用');
    }
  });

  test('以图搜图要给素材 id 或 fileKey，不是关键词', () {
    expect(SearchMode.image.needsMaterial, isTrue);
    expect(SearchMode.content.needsMaterial, isFalse);
  });

  test('按标签搜不需要关键词——标签是从参考镜带过来的', () {
    expect(SearchMode.tags.needsKeyword, isFalse);
    expect(SearchMode.content.needsKeyword, isTrue);
    expect(SearchMode.voiceover.needsKeyword, isTrue);
  });
}
