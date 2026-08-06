import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/picking/tag_hit_probe.dart';
import 'package:ishkafel/features/picking/tag_query_narrowing.dart';

TagHit h(String n, int id, int c) => TagHit(name: n, tagId: id, count: c);

void main() {
  // 数字取自真机：滴露植源喷雾（项目 104）下各标签单独检索的条数
  test('真机三个镜头：收紧之后检索键各不相同', () {
    final s1 = narrowTagQuery(hits: [
      h('灶台', 1, 352),
      h('实拍', 2, 5437),
      h('口播', 3, 182),
      h('达人背书', 4, 0),
      h('大字报', 5, 0),
      h('剧情', 6, 0),
    ]);
    final s2 = narrowTagQuery(hits: [
      h('橱柜', 7, 8),
      h('实拍', 2, 5437),
      h('人物喷', 8, 38),
      h('厨房情景', 9, 256),
    ]);
    final s3 = narrowTagQuery(hits: [
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
    // 常规清洁 1947 条（占项目三分之一）也被判为宽泛：留着它 S3 会搜出
    // 2014 条，剔掉后是 293 条——真机实测
    expect(s3.tagIds, [10, 8, 9]);
    expect(s3.droppedBroad, ['实拍', '常规清洁']);

    // 此前三个镜头搜出来的东西一模一样，就是因为并集永远被「实拍」撑满
    expect({s1.tagIds.join(), s2.tagIds.join(), s3.tagIds.join()}, hasLength(3),
        reason: '三个镜头必须搜出三份不同的结果');
  });
}
