import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/picking/tag_hit_probe.dart';
import 'package:ishkafel/features/picking/tag_query_narrowing.dart';

TagHit h(String n, int id, int c) => TagHit(name: n, tagId: id, count: c);

void main() {
  group('滴露植源喷雾（项目 104，共 6012 条分镜）', () {
    // 数字取自真机：各标签单独检索的条数
    const total = 6012;

    test('三个镜头收紧之后检索键各不相同', () {
      final s1 = narrowTagQuery(libraryTotal: total, hits: [
        h('灶台', 1, 352),
        h('实拍', 2, 5437),
        h('口播', 3, 182),
        h('达人背书', 4, 0),
        h('大字报', 5, 0),
        h('剧情', 6, 0),
      ]);
      final s2 = narrowTagQuery(libraryTotal: total, hits: [
        h('橱柜', 7, 8),
        h('实拍', 2, 5437),
        h('人物喷', 8, 38),
        h('厨房情景', 9, 256),
      ]);
      final s3 = narrowTagQuery(libraryTotal: total, hits: [
        h('冰箱玻璃板', 10, 55),
        h('实拍', 2, 5437),
        h('人物喷', 8, 38),
        h('常规清洁', 11, 1947),
        h('厨房情景', 9, 256),
      ]);

      // 真机实测收紧后的命中数：S1 528 条、S2 276 条、S3 293 条，
      // 而收紧前三者都是 5437 条且第一页完全相同
      expect(s1.tagIds, [1, 3], reason: '灶台 + 口播');
      expect(s1.droppedBroad, ['实拍']);
      expect(s1.droppedEmpty, ['达人背书', '大字报', '剧情']);

      expect(s2.tagIds, [7, 8, 9], reason: '橱柜 + 人物喷 + 厨房情景');
      // 常规清洁 1947 条（占项目 32%）也是宽泛：留着它 S3 会搜出 2014 条，
      // 剔掉后是 293 条——真机实测
      expect(s3.tagIds, [10, 8, 9]);
      expect(s3.droppedBroad, ['实拍', '常规清洁']);

      // 此前三个镜头搜出来的东西一模一样，就是因为并集永远被「实拍」撑满
      expect({s1.tagIds.join(), s2.tagIds.join(), s3.tagIds.join()},
          hasLength(3),
          reason: '三个镜头必须搜出三份不同的结果');
    });
  });

  group('植源AI（项目 146，共 788 条分镜）', () {
    // 小项目：命中数是 501/113/65/64/58/13。早先「找最大断层」的写法在这里
    // 会把断层判在 65→13 上，于是电饭煲表面、冰箱玻璃板、实拍全被当成宽泛
    // 剔掉，每个镜头都只剩「厨房情景」——切 S1/S2/S3 搜的是同一个查询。
    // 用户原话：「我感觉你在切 S1、S2、S3 的时候，筛选条件没有变」。
    const total = 788;

    TagQueryPlan s1() => narrowTagQuery(libraryTotal: total, hits: [
          h('餐桌', 20, 0),
          h('实拍', 2, 113),
          h('常规清洁', 11, 501),
          h('厨房情景', 9, 13),
        ]);
    TagQueryPlan s2() => narrowTagQuery(libraryTotal: total, hits: [
          h('冰箱玻璃板', 10, 64),
          h('实拍', 2, 113),
          h('人物喷', 8, 0),
          h('常规清洁', 11, 501),
          h('细菌清洁', 21, 58),
          h('厨房情景', 9, 13),
        ]);
    TagQueryPlan s4() => narrowTagQuery(libraryTotal: total, hits: [
          h('电饭煲表面', 22, 65),
          h('实拍', 2, 113),
          h('人物喷', 8, 0),
          h('常规清洁', 11, 501),
          h('厨房情景', 9, 13),
        ]);

    test('只剔掉真的覆盖过大的那个，具体标签一个不动', () {
      expect(s1().tagIds, [2, 9], reason: '实拍 14% + 厨房情景 1.7%，都留下');
      expect(s1().droppedBroad, ['常规清洁'], reason: '501/788 = 64%');
      expect(s1().droppedEmpty, ['餐桌']);

      expect(s4().tagIds, [22, 2, 9],
          reason: '电饭煲表面 8.3% 是这个镜头最有区分度的标签，不能剔');
    });

    test('切镜头时检索键真的跟着变', () {
      expect(s2().tagIds, isNot(s4().tagIds));
      expect(s1().tagIds, isNot(s4().tagIds));
    });

    test('标签相同的两个镜头搜出同一批——这是对的，不是 bug', () {
      // U2 的 S1 和 S3 打的标签一模一样（都是 餐桌/实拍/常规清洁/厨房情景）
      expect(s1().tagIds, narrowTagQuery(libraryTotal: total, hits: [
            h('餐桌', 20, 0),
            h('实拍', 2, 113),
            h('常规清洁', 11, 501),
            h('厨房情景', 9, 13),
          ]).tagIds);
    });
  });

  group('分母拿不到时', () {
    test('不做宽泛剔除——不确定时不做减法', () {
      final plan = narrowTagQuery(hits: [
        h('实拍', 2, 5437),
        h('灶台', 1, 352),
        h('达人背书', 4, 0),
      ]);

      expect(plan.tagIds, [2, 1]);
      expect(plan.droppedBroad, isEmpty);
      expect(plan.droppedEmpty, ['达人背书'], reason: '0 条的照剔——那个不需要分母');
    });
  });
}
