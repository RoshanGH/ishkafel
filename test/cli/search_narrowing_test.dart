import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/search_narrowing.dart';

/// 检索的**收窄条件**：不能让它全库瞎搜。
///
/// 真机翻车：任务选了「AI自然消毒液原子库」两个标签组，搜出来却混进大量
/// Hi!papa 防晒乳、Roye 洗护、杜蕾斯——跟滴露毫无关系。
///
/// 两道约束同时失效了：
/// - `project` 是 null（`ui new-task` 根本没让 Agent 选项目）
/// - 参考镜没打标 → 标签为空 → 旧代码直接 `return []` 放弃全部标签约束
///
/// 收窄不上就**明说**，别让调用方以为搜到的就是对的。
void main() {
  group('说清这一轮是按什么收窄的', () {
    test('两道都在：按项目 + 标签', () {
      final n = describeNarrowing(projectIds: const [7], tagIds: const [1, 2]);
      expect(n.narrowed, isTrue);
      expect(n.notice, isNull);
    });

    test('只有项目也算收窄', () {
      expect(describeNarrowing(projectIds: const [7], tagIds: const []).narrowed,
          isTrue);
    });

    test('只有标签也算', () {
      expect(describeNarrowing(projectIds: const [], tagIds: const [3]).narrowed,
          isTrue);
    });

    test('两道都没有：**必须说出来**，这一轮是在全库里捞', () {
      final n = describeNarrowing(projectIds: const [], tagIds: const []);
      expect(n.narrowed, isFalse);
      expect(n.notice, isNotNull);
      expect(n.notice!, contains('全库'));
      expect(n.notice!, contains('tag-ref'),
          reason: '要给出怎么收窄——打标是拿到标签的唯一路子');
    });
  });
}
