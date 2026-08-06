import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/picking/candidate_ranking.dart';

void main() {
  group('命中了哪几个标签——只说个数，用户判断不了这条到底像不像', () {
    test('列出真正命中的那几个，按检索标签的顺序', () {
      final hit = CandidateRanking.matchedTags(
        materialTags: const ['灶台', '实拍', '别的'],
        queryTags: const ['灶台', '常规清洁', '实拍', '厨房情景'],
      );

      expect(hit, ['灶台', '实拍'],
          reason: '按检索标签的顺序而不是素材标签的顺序——'
              '用户是照着自己选的那几个标签在看');
    });

    test('一个都没命中就是空', () {
      expect(
          CandidateRanking.matchedTags(
              materialTags: const ['甲'], queryTags: const ['乙']),
          isEmpty);
    });

    test('检索标签重复时不重复列出', () {
      expect(
          CandidateRanking.matchedTags(
              materialTags: const ['灶台'],
              queryTags: const ['灶台', '灶台']),
          ['灶台']);
    });

    test('素材标签重复时也只算一次', () {
      expect(
          CandidateRanking.matchedTags(
              materialTags: const ['灶台', '灶台'],
              queryTags: const ['灶台']),
          ['灶台']);
    });

    test('命中个数与列出的条数始终一致', () {
      const material = ['灶台', '实拍', '口播'];
      const query = ['灶台', '常规清洁', '实拍'];

      expect(
          CandidateRanking.matchedTags(
                  materialTags: material, queryTags: query)
              .length,
          CandidateRanking.overlap(material, query),
          reason: '两处各算一遍迟早会对不上，界面上就会出现「命中 3 个」却只列出 2 个');
    });
  });
}
