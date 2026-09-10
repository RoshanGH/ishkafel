import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/balanced_sample.dart';

/// 每一位上各个取值出现几次
Map<int, int> _countsAt(List<List<int>> vectors, int position) {
  final m = <int, int>{};
  for (final v in vectors) {
    m[v[position]] = (m[v[position]] ?? 0) + 1;
  }
  return m;
}

void main() {
  test('5 个候选挑 10 条：各出现两次，一个不落', () {
    final v = balancedVectors(const [5], 10);
    expect(v, hasLength(10));
    expect(_countsAt(v, 0), {0: 2, 1: 2, 2: 2, 3: 2, 4: 2});
  });

  test('除不尽时最多差一次——不许有的三次有的一次', () {
    final v = balancedVectors(const [3], 10);
    final counts = _countsAt(v, 0).values.toList()..sort();
    expect(counts, [3, 3, 4]);
  });

  test('每一位各自均衡，互不牵连', () {
    final v = balancedVectors(const [5, 40, 2], 20);
    expect(_countsAt(v, 0).values.toSet(), {4});
    expect(_countsAt(v, 1).values.toSet(), {1}, reason: '40 里取 20 条，各不重复');
    expect(_countsAt(v, 2).values.toSet(), {10});
  });

  test('位数相同的两位不许齐步走——否则搭配永远是那几种', () {
    // 两位都是 5 个候选、挑 25 条：如果齐步走，只会出现 (0,0)(1,1)… 5 种搭配
    final v = balancedVectors(const [5, 5], 25);
    final pairs = {for (final e in v) '${e[0]}-${e[1]}'};
    expect(pairs.length, greaterThan(15),
        reason: '25 条里搭配只有 ${pairs.length} 种，等于两位绑死了');
  });

  test('结果稳定：同样的输入给同样的结果', () {
    expect(balancedVectors(const [5, 7, 3], 12).toString(),
        balancedVectors(const [5, 7, 3], 12).toString());
  });

  test('只有一个取值的位就一直是它', () {
    final v = balancedVectors(const [1, 4], 8);
    expect(_countsAt(v, 0), {0: 8});
    expect(_countsAt(v, 1).values.toSet(), {2});
  });

  test('要 0 条给空；没有可变位时给的每条都一样', () {
    expect(balancedVectors(const [3], 0), isEmpty);
    expect(balancedVectors(const [], 3), [[], [], []]);
  });
}
