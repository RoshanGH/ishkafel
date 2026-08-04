import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/miaoa/miaoa_content_service.dart';
import 'package:ishkafel/features/picking/candidate_ranking.dart';
import 'package:ishkafel/features/picking/candidate_search_controller.dart';

CandidateEntry _entry(int id, List<String> tags) => CandidateEntry(
      material: CandidateMaterial(
        id: id,
        name: '素材$id',
        sceneDescription: '',
        thumbnailUrl: null,
        previewUrl: null,
        fileKey: null,
        tags: tags,
      ),
      probing: true,
    );

void main() {
  group('命中几个检索标签', () {
    test('数的是交集，不是素材自己有多少标签', () {
      expect(
          CandidateRanking.overlap(
              const ['厨房情景', '实拍', '打开电器'], const ['厨房情景', '打开电器']),
          2);
    });

    test('重复的标签只算一次', () {
      expect(
          CandidateRanking.overlap(
              const ['厨房情景', '厨房情景'], const ['厨房情景', '厨房情景']),
          1);
    });

    test('一个都没命中就是 0', () {
      expect(CandidateRanking.overlap(const ['实拍'], const ['厨房情景']), 0);
    });
  });

  group('按重合度重排', () {
    test('命中多的排前面', () {
      final ranked = CandidateRanking.byTagOverlap(
        [
          _entry(1, const ['实拍']),
          _entry(2, const ['厨房情景', '打开电器', '实拍']),
          _entry(3, const ['厨房情景', '打开电器']),
        ],
        const ['厨房情景', '打开电器', '实拍'],
      );

      expect(ranked.map((e) => e.material.id), [2, 3, 1],
          reason: '素材库按「任一命中」检索、又按入库时间倒序返回，'
              '不重排的话第一页是「最近入库的沾边素材」');
    });

    test('同分的保持素材库给的原顺序', () {
      final ranked = CandidateRanking.byTagOverlap(
        [
          _entry(1, const ['厨房情景']),
          _entry(2, const ['打开电器']),
          _entry(3, const ['厨房情景']),
        ],
        const ['厨房情景', '打开电器'],
      );

      expect(ranked.map((e) => e.material.id), [1, 2, 3],
          reason: 'Dart 的 List.sort 不保证稳定；同分条目每次刷新都换位置，'
              '用户会以为列表在自己乱动');
    });

    test('一个都没命中的排最后，但不丢掉', () {
      final ranked = CandidateRanking.byTagOverlap(
        [
          _entry(1, const []),
          _entry(2, const ['厨房情景']),
        ],
        const ['厨房情景'],
      );

      expect(ranked.map((e) => e.material.id), [2, 1]);
    });

    test('没有检索标签时原样返回，不做无谓的重排', () {
      final entries = [_entry(1, const ['甲']), _entry(2, const ['乙'])];

      expect(CandidateRanking.byTagOverlap(entries, const []), same(entries));
    });
  });
}
