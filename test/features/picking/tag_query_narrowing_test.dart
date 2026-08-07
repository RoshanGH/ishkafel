import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/picking/tag_hit_probe.dart';
import 'package:ishkafel/features/picking/tag_query_narrowing.dart';

TagHit hit(String name, int id, int? count) =>
    TagHit(name: name, tagId: id, count: count);

void main() {
  group('把没有区分度的标签剔出检索键', () {
    test('本项目下一条素材都没有的标签直接丢掉——它对「满足其一」毫无贡献', () {
      final plan = narrowTagQuery(libraryTotal: 6012, hits: [
        hit('灶台', 1, 352),
        hit('达人背书', 2, 0),
        hit('大字报', 3, 0),
      ]);

      expect(plan.tagIds, [1]);
      expect(plan.droppedEmpty, ['达人背书', '大字报']);
    });

    test('几乎命中全项目的标签也丢掉——它一个人就把并集撑满了', () {
      // 实测：S1 六个标签搜出 5437 条，而「实拍」单独搜也是 5437 条
      final plan = narrowTagQuery(libraryTotal: 6012, hits: [
        hit('灶台', 1, 352),
        hit('实拍', 2, 5437),
        hit('口播', 3, 182),
      ]);

      expect(plan.tagIds, [1, 3]);
      expect(plan.droppedBroad, ['实拍']);
    });

    test('三个镜头标签不同，收紧后检索键就不同了——这正是要修的', () {
      final s1 = narrowTagQuery(libraryTotal: 6012, hits: [
        hit('灶台', 1, 352),
        hit('实拍', 2, 5437),
        hit('口播', 3, 182),
        hit('达人背书', 4, 0),
      ]);
      final s2 = narrowTagQuery(libraryTotal: 6012, hits: [
        hit('橱柜', 5, 8),
        hit('实拍', 2, 5437),
        hit('人物喷', 6, 38),
        hit('厨房情景', 7, 256),
      ]);

      expect(s1.tagIds, isNot(s2.tagIds),
          reason: '此前 51 个镜头全带「实拍」，并集永远是同一个 5437 条，'
              '搜出来的东西一模一样');
    });

    test('只剩一个能用的标签时就用它，哪怕它很宽泛', () {
      final plan = narrowTagQuery(libraryTotal: 6012, hits: [
        hit('实拍', 1, 5437),
        hit('别的', 2, 0),
      ]);

      expect(plan.tagIds, [1], reason: '没有别的标签可比，谈不上「没有区分度」');
      expect(plan.droppedEmpty, ['别的']);
    });

    test('所有标签在本项目下都是 0 条时退回原样——搜得宽也好过搜不出来', () {
      final plan = narrowTagQuery(hits: [
        hit('甲', 1, 0),
        hit('乙', 2, 0),
      ]);

      expect(plan.tagIds, [1, 2]);
      expect(plan.fellBack, isTrue);
      expect(plan.droppedEmpty, isEmpty, reason: '退回原样时不该再说「已排除」');
    });

    test('数不出条数的标签保留——不确定时不做减法', () {
      final plan = narrowTagQuery(libraryTotal: 6012, hits: [
        hit('灶台', 1, 352),
        hit('查不到', 2, null),
      ]);

      expect(plan.tagIds, [1, 2]);
    });

    test('唯一的标签就算覆盖全项目也照用——剔光了等于搜不了', () {
      final plan = narrowTagQuery(libraryTotal: 6012, hits: [
        hit('实拍', 1, 5437),
      ]);

      expect(plan.tagIds, [1]);
      expect(plan.fellBack, isTrue);
    });

    test('宽不宽看它占本项目的多少，不拿标签之间互相比', () {
      // 同样是 1000 条：在 2000 条的项目里是一半，在 20000 条里是二十分之一
      expect(
          narrowTagQuery(libraryTotal: 2000, hits: [
            hit('宽', 1, 1000),
            hit('窄', 2, 30),
          ]).droppedBroad,
          ['宽']);
      expect(
          narrowTagQuery(libraryTotal: 20000, hits: [
            hit('不宽', 1, 1000),
            hit('窄', 2, 30),
          ]).droppedBroad,
          isEmpty);
    });

    test('小项目里的具体标签不会被误伤', () {
      // 真机项目 146（788 条）：早先「找最大断层」会把断层判在 65→13，
      // 于是电饭煲表面、实拍全被剔掉，每个镜头只剩「厨房情景」，
      // 切 S1/S2/S3 搜的是同一个查询
      final plan = narrowTagQuery(libraryTotal: 788, hits: [
        hit('电饭煲表面', 1, 65),
        hit('实拍', 2, 113),
        hit('常规清洁', 3, 501),
        hit('厨房情景', 4, 13),
      ]);

      expect(plan.tagIds, [1, 2, 4]);
      expect(plan.droppedBroad, ['常规清洁'], reason: '501/788 = 64%');
    });

    test('几个标签命中数相近时都留着——那说明它们各有各的区分度', () {
      final plan = narrowTagQuery(libraryTotal: 6012, hits: [
        hit('甲', 1, 300),
        hit('乙', 2, 280),
        hit('丙', 3, 260),
      ]);

      expect(plan.tagIds, [1, 2, 3]);
      expect(plan.droppedBroad, isEmpty);
    });

    test('空输入不炸', () {
      expect(narrowTagQuery(hits: const []).tagIds, isEmpty);
    });
  });
}
