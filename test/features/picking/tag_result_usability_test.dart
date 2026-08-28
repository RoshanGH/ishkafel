import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/picking/tag_result_usability.dart';

/// 收窄之后**还是没筛住**这件事，以前没人管。
///
/// 真机：一个 35 镜的任务，每一镜按标签搜出来都是 `total: 11265`，
/// 而素材库返回的 50 条是**按 id 倒序的最新 50 条**——标签检索没有相关性
/// 排序。第一镜要「女孩在书桌前情绪激动诉说」，首条给的是「户外街道上
/// 女士与男孩并排走着交谈」。换画面描述语义搜：554 条，前十条几乎全对。
///
/// 这条路人和 Agent 都在走——界面默认也是标签模式。
void main() {
  test('命中上万条：前几页就是随机取样', () {
    expect(tagResultIsUsable(total: 11265, returned: 50),
        isFalse);
  });

  test('命中一两页：最新和最像的差别还不致命', () {
    expect(
        tagResultIsUsable(total: 120, returned: 50), isTrue);
  });

  test('刚好四页还行，第五页起就翻不完了', () {
    expect(tagResultIsUsable(total: 200, returned: 50),
        isTrue);
    expect(tagResultIsUsable(total: 201, returned: 50),
        isFalse);
  });

  test('一页装得下就是全部命中，没有取样问题', () {
    expect(
        tagResultIsUsable(total: 37, returned: 37), isTrue);
  });

  test('一条都没有也算没筛住——要换条路，不是让人对着空列表发呆', () {
    expect(
        tagResultIsUsable(total: 0, returned: 0), isFalse);
  });
}
