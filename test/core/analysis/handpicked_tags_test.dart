import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/handpicked_tags.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';

/// **人改过的标签，重新打标时不许盖掉。**
///
/// 属性栏和审核页都能手改标签。改完再点「重新打标」，模型会照着台词重打一遍
/// ——把人刚判断过的结论抹掉，而且不问一声。人不会想到「我改的东西被一个
/// 后台步骤盖了」，只会觉得改了没生效。
SemanticUnit _u(int index, {bool handpicked = false, List<Shot> shots = const []}) =>
    SemanticUnit(
      index: index,
      startMs: index * 1000,
      endMs: (index + 1) * 1000,
      transcript: 'U${index + 1}',
      tagsHandpicked: handpicked,
      shots: shots,
    );

Shot _s(int start, {bool handpicked = false}) =>
    Shot(startMs: start, endMs: start + 500, tagsHandpicked: handpicked);

void main() {
  group('哪些该跳过', () {
    test('人改过的单元，重打标时跳过', () {
      final units = [_u(0), _u(1, handpicked: true), _u(2)];

      expect(unitsToRetag(units), {0, 2});
    });

    test('单元没改过、但里面有镜头改过：单元照打，那个镜头跳过', () {
      final units = [
        _u(0, shots: [_s(0), _s(500, handpicked: true)]),
      ];

      expect(unitsToRetag(units), {0});
      expect(shotsToSkip(units[0]), {1});
    });

    test('一个都没改过就全打', () {
      expect(unitsToRetag([_u(0), _u(1)]), {0, 1});
      expect(shotsToSkip(_u(0, shots: [_s(0), _s(500)])), isEmpty);
    });
  });

  group('手改这件事本身', () {
    test('手改之后标记为「人改过」，并且不再算过期', () {
      const before = SemanticUnit(
          index: 0, startMs: 0, endMs: 1000, transcript: 'U1',
          tags: ['旧'], tagsStale: true);

      final after = withHandpickedTags(before, ['促单', '痛点']);

      expect(after.tags, ['促单', '痛点']);
      expect(after.tagsHandpicked, isTrue);
      expect(after.tagsStale, isFalse,
          reason: '「过期」说的是模型打的标签配不上现在的边界；人刚照着画面判断过，'
              '就不该再挂着一个催他重打的标记');
    });

    test('镜头同理', () {
      const before = Shot(startMs: 0, endMs: 500, tags: ['旧'], tagsStale: true);

      final after = withHandpickedShotTags(before, ['实拍']);

      expect(after.tags, ['实拍']);
      expect(after.tagsHandpicked, isTrue);
      expect(after.tagsStale, isFalse);
    });

    test('存量数据默认不是人改的——老任务的标签都是模型打的', () {
      expect(const SemanticUnit(
              index: 0, startMs: 0, endMs: 1, transcript: '')
          .tagsHandpicked, isFalse);
      expect(const Shot(startMs: 0, endMs: 1).tagsHandpicked, isFalse);
    });
  });
}
