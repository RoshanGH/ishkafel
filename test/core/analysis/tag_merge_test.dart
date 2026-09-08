import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/tag_merge.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';

Shot _shot(int start, int end, {List<String> tags = const []}) =>
    Shot(startMs: start, endMs: end, tags: tags);

SemanticUnit _unit(
  int index,
  int start,
  int end, {
  List<String> tags = const [],
  List<Shot> shots = const [],
  bool tagsStale = false,
}) =>
    SemanticUnit(
      index: index,
      startMs: start,
      endMs: end,
      transcript: 't$index',
      tags: tags,
      tagsStale: tagsStale,
      shots: shots,
    );

void main() {
  group('打标结果合并回当前单元', () {
    test('边界没变就把标签补上', () {
      final current = [
        _unit(0, 0, 1000, shots: [_shot(0, 500)]),
      ];
      final tagged = [
        _unit(0, 0, 1000,
            tags: ['促单'], shots: [_shot(0, 500, tags: ['实拍'])]),
      ];

      final merged = mergeTagsInto(current, tagged);

      expect(merged.single.tags, ['促单']);
      expect(merged.single.shots.single.tags, ['实拍']);
    });

    test('用户在打标期间拖过边界的单元，不安旧标签', () {
      // 打标要跑总时长七成，这七成里人就坐在工作台改切分
      final current = [_unit(0, 0, 1200)];
      final tagged = [_unit(0, 0, 1000, tags: ['促单'])];

      final merged = mergeTagsInto(current, tagged);

      expect(merged.single.tags, isEmpty,
          reason: '这份标签是照着 0~1000 打的，安到 0~1200 上就是错的');
      expect(merged.single.endMs, 1200, reason: '用户的改动必须原样保留');
    });

    test('单元没动但镜头动了，只跳过那个镜头', () {
      final current = [
        _unit(0, 0, 1000, shots: [_shot(0, 500), _shot(500, 800)]),
      ];
      final tagged = [
        _unit(0, 0, 1000, tags: ['促单'], shots: [
          _shot(0, 500, tags: ['实拍']),
          _shot(500, 1000, tags: ['口播']),
        ]),
      ];

      final merged = mergeTagsInto(current, tagged);

      expect(merged.single.tags, ['促单']);
      expect(merged.single.shots.first.tags, ['实拍']);
      expect(merged.single.shots.last.tags, isEmpty,
          reason: '这个镜头的边界被改过，旧标签不作数');
    });

    test('当前单元已有标签就不覆盖（用户或重新打标写的更新）', () {
      final current = [_unit(0, 0, 1000, tags: ['人工改过'])];
      final tagged = [_unit(0, 0, 1000, tags: ['促单'])];

      expect(mergeTagsInto(current, tagged).single.tags, ['人工改过']);
    });

    test('数量对不上也不会崩，能配上的照常合并', () {
      final current = [_unit(0, 0, 1000), _unit(1, 1000, 2000)];
      final tagged = [_unit(0, 0, 1000, tags: ['促单'])];

      final merged = mergeTagsInto(current, tagged);

      expect(merged.first.tags, ['促单']);
      expect(merged.last.tags, isEmpty);
    });

    test('没有标签可合并时原样返回入参本身（调用方靠它避免灌满 undo 栈）', () {
      final current = [_unit(0, 0, 1000, tags: ['促单'])];
      final tagged = [_unit(0, 0, 1000, tags: ['促单'])];

      expect(identical(mergeTagsInto(current, tagged), current), isTrue);
    });

    test('原列表不被改动（合并出的是新列表）', () {
      final current = [_unit(0, 0, 1000)];
      final tagged = [_unit(0, 0, 1000, tags: ['促单'])];

      mergeTagsInto(current, tagged);

      expect(current.single.tags, isEmpty);
    });
  });
}
