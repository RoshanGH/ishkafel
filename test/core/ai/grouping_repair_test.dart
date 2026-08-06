import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/grouping_repair.dart';

void main() {
  group('按 AI 给的分段起点重建一份合法分组', () {
    test('本来就合法时原样不动', () {
      final r = GroupingRepair.of([
        [0, 1, 2],
        [3, 4],
      ], total: 5);

      expect(r.groups, [
        [0, 1, 2],
        [3, 4],
      ]);
      expect(r.changed, isFalse);
    });

    test('漏掉的句子并进前一个单元，而不是把整份分组扔掉', () {
      // 模型给了 [0,1] 和 [3,4]，第 2 句谁也没要
      final r = GroupingRepair.of([
        [0, 1],
        [3, 4],
      ], total: 5);

      expect(r.groups, [
        [0, 1, 2],
        [3, 4],
      ], reason: '一句一个单元是最差的兜底：27 句 ASR 会切出 27 个单元');
      expect(r.changed, isTrue);
    });

    test('重复的句子归先出现的那个单元，边界按模型的意思留住', () {
      final r = GroupingRepair.of([
        [0, 1, 2],
        [2, 3],
      ], total: 4);

      expect(r.groups, [
        [0, 1],
        [2, 3],
      ], reason: '模型在第 2 句处想要一刀，这个意图要留住');
      expect(r.changed, isTrue);
    });

    test('顺序乱了也能排回来', () {
      final r = GroupingRepair.of([
        [3, 4],
        [0, 1, 2],
      ], total: 5);

      expect(r.groups, [
        [0, 1, 2],
        [3, 4],
      ]);
    });

    test('开头没被覆盖时补上，绝不丢句子', () {
      final r = GroupingRepair.of([
        [2, 3],
      ], total: 4);

      expect(r.groups, [
        [0, 1],
        [2, 3],
      ]);
    });

    test('越界索引丢掉，剩下的照用', () {
      final r = GroupingRepair.of([
        [0, 1],
        [2, 99],
        [-1],
      ], total: 3);

      expect(r.groups, [
        [0, 1],
        [2],
      ]);
    });

    test('空组跳过，不产出空单元', () {
      final r = GroupingRepair.of([
        [],
        [0, 1],
      ], total: 2);

      expect(r.groups, [
        [0, 1],
      ]);
    });

    test('一句话不落——修完的分组永远是完整覆盖', () {
      final r = GroupingRepair.of([
        [1],
        [1, 5],
        [],
        [3],
      ], total: 8);

      expect(r.groups.expand((g) => g).toList(),
          [for (var i = 0; i < 8; i++) i],
          reason: '修复的底线是不丢内容，否则成片会缺一段台词');
    });

    test('一个可用索引都没有时说不出话，交给调用方兜底', () {
      final r = GroupingRepair.of([
        [99],
        [],
      ], total: 3);

      expect(r.groups, isEmpty);
    });

    test('没有分组时也交给调用方兜底', () {
      expect(GroupingRepair.of(const [], total: 3).groups, isEmpty);
    });
  });
}
