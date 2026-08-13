import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/diverse_pick.dart';
import 'package:ishkafel/core/export/export_plan.dart';
import 'package:ishkafel/core/replacement/picked_material.dart';

/// 从全部排列组合里挑 K 条「最不一样」的。
///
/// 存在的理由：5 个分子各选 3 条素材就是 243 条组合，全导出去没人看得完，
/// 也没意义——真正要的是**几条彼此差异明显的**拿去投放测试。
///
/// 最直接的定义（有几个位置换了素材）是错的：同一批拍摄切出来的素材画面
/// 几乎一样，按位置数它们「不同」，眼睛看是一模一样。所以距离要算在素材
/// 本身的相似度上。
void main() {
  ExportCombination comboOf(int index, List<int> materialIds) =>
      ExportCombination(
        index: index,
        segments: [
          for (var i = 0; i < materialIds.length; i++)
            ExportSegment(
              startMs: i * 1000,
              endMs: (i + 1) * 1000,
              unitIndex: i,
              candidateId: materialIds[i],
            ),
        ],
      );

  PickedMaterial material(int id, {String? name, String? scene}) =>
      PickedMaterial(
        id: id,
        name: name ?? '素材$id',
        voiceover: '',
        sceneDescription: scene ?? '',
      );

  group('挑几条', () {
    test('要的比有的多时全给，不硬凑', () {
      final all = [comboOf(1, [101]), comboOf(2, [102])];
      final picked = pickDiverse(all, count: 5, materials: const []);
      expect(picked, hasLength(2));
    });

    test('要 0 条或负数时给空，不当成「全要」', () {
      final all = [comboOf(1, [101]), comboOf(2, [102])];
      expect(pickDiverse(all, count: 0, materials: const []), isEmpty);
      expect(pickDiverse(all, count: -3, materials: const []), isEmpty);
    });

    test('结果稳定：同样的输入挑出同样的几条', () {
      // 不用随机数——同一个方案挑两次给出不同结果的话，用户会以为自己看错了
      final all = [
        for (var i = 0; i < 20; i++) comboOf(i + 1, [100 + i, 200 + i]),
      ];
      final first = pickDiverse(all, count: 5, materials: const []);
      final second = pickDiverse(all, count: 5, materials: const []);
      expect(first.map((c) => c.index), second.map((c) => c.index));
    });
  });

  group('距离算在素材相似度上', () {
    test('同一批拍摄的素材不算「差异」', () {
      // 名字同前缀、id 相邻 = 同一条原片切出来的，画面几乎一样
      final mats = [
        material(101, name: '滴露_植源_姚瑶_20260702_001'),
        material(102, name: '滴露_植源_姚瑶_20260702_002'),
        material(900, name: '完全不同的另一批_厨房_A'),
      ];
      final all = [
        comboOf(1, [101]),
        comboOf(2, [102]), // 跟 1 几乎一样
        comboOf(3, [900]), // 跟 1 差很远
      ];

      final picked = pickDiverse(all, count: 2, materials: mats);
      final ids = picked.map((c) => c.index).toSet();
      expect(ids, contains(3), reason: '差最远的那条必须在');
      expect(ids.length, 2);
      expect(ids.contains(1) || ids.contains(2), isTrue);
      expect(ids.containsAll({1, 2}), isFalse,
          reason: '1 和 2 几乎一样，不该同时被挑走');
    });

    test('画面描述差得远的judged为更不一样', () {
      final mats = [
        material(101, scene: '厨房 灶台 油污 擦拭'),
        material(102, scene: '厨房 灶台 油污 清洁'),
        material(900, scene: '客厅 沙发 宝宝 玩具'),
      ];
      final all = [comboOf(1, [101]), comboOf(2, [102]), comboOf(3, [900])];
      final picked = pickDiverse(all, count: 2, materials: mats);
      expect(picked.map((c) => c.index), contains(3));
    });
  });

  group('覆盖：没露过面的素材要被带出来', () {
    test('挑出来的组合尽量把不同素材都用上', () {
      // 投放测试的实际用途：没露过面的素材根本测不出效果
      final all = [
        comboOf(1, [101, 201]),
        comboOf(2, [101, 202]),
        comboOf(3, [102, 201]),
        comboOf(4, [102, 202]),
      ];
      final picked = pickDiverse(all, count: 2, materials: const []);
      final used = <int>{
        for (final c in picked)
          for (final s in c.segments) ?s.candidateId,
      };
      expect(used, hasLength(4), reason: '两条组合应该把 4 条素材都用上');
    });
  });

  group('两两都不接近（max-min，不是 max-sum）', () {
    test('不会为了「总距离大」而放两条几乎一样的进来', () {
      final mats = [
        material(101, name: 'A批_001'),
        material(102, name: 'A批_002'),
        material(900, name: 'B批_001'),
        material(901, name: 'C批_001'),
      ];
      final all = [
        comboOf(1, [101]),
        comboOf(2, [102]),
        comboOf(3, [900]),
        comboOf(4, [901]),
      ];
      final picked = pickDiverse(all, count: 3, materials: mats);
      final ids = picked.map((c) => c.index).toSet();
      // 1 和 2 是同一批，三条里最多进一条
      expect(ids.containsAll({1, 2}), isFalse);
    });
  });
}
