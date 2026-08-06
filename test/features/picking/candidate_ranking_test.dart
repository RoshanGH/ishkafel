import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/picking/candidate_ranking.dart';

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
}
