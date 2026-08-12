import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/blank_unit_ops.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';

/// 空白任务的分子编辑。
///
/// 跟 [SegmentationEditOps] 是两套不变量，所以分开：那边有一条固定的原片
/// 总长要无缝覆盖，这边没有原片，分子可以随便增删排序，**总长是加出来的**。
///
/// 共同点只有一条：绝不原地修改，一律返回新列表。
void main() {
  List<SemanticUnit> unitsOf(int count) {
    var list = <SemanticUnit>[];
    for (var i = 0; i < count; i++) {
      list = BlankUnitOps.append(list);
    }
    return list;
  }

  group('添加', () {
    test('加到末尾，下标连续，首尾相接', () {
      final units = unitsOf(3);
      expect(units.map((u) => u.index), [0, 1, 2]);
      expect(units[0].startMs, 0);
      for (var i = 1; i < units.length; i++) {
        expect(units[i].startMs, units[i - 1].endMs, reason: '必须首尾相接');
      }
    });

    test('新分子没有台词、没有镜头——这两样本来就不存在', () {
      final unit = BlankUnitOps.append(const []).single;
      expect(unit.transcript, isEmpty);
      expect(unit.shots, isEmpty);
      expect(unit.tags, isEmpty);
    });

    test('没挑素材时占一个占位长度，不是 0', () {
      // 0 长度的格子在时间线上是零宽，看不见也点不到
      final unit = BlankUnitOps.append(const []).single;
      expect(unit.durationMs, BlankUnitOps.placeholderMs);
    });

    test('可以带着标签一起加', () {
      final unit = BlankUnitOps.append(const [], tags: ['厨房情景']).single;
      expect(unit.tags, ['厨房情景']);
    });
  });

  group('删除', () {
    test('删中间那个，后面的下标补齐、时间重新首尾相接', () {
      final units = BlankUnitOps.removeAt(unitsOf(3), 1);
      expect(units, hasLength(2));
      expect(units.map((u) => u.index), [0, 1]);
      expect(units[1].startMs, units[0].endMs);
    });

    test('删不存在的下标原样返回，不抛', () {
      final before = unitsOf(2);
      expect(BlankUnitOps.removeAt(before, 9), same(before));
      expect(BlankUnitOps.removeAt(before, -1), same(before));
    });

    test('删到一个不剩也是合法状态', () {
      var units = unitsOf(1);
      units = BlankUnitOps.removeAt(units, 0);
      expect(units, isEmpty);
    });
  });

  group('排序', () {
    test('往后拖：中间的往前补位，下标全部重排', () {
      final units = BlankUnitOps.setTags(unitsOf(3), 0, ['甲']);
      final moved = BlankUnitOps.move(units, 0, 2);
      expect(moved.map((u) => u.index), [0, 1, 2]);
      expect(moved.last.tags, ['甲'], reason: '被拖的那个应该到了末尾');
    });

    test('往前拖', () {
      final units = BlankUnitOps.setTags(unitsOf(3), 2, ['丙']);
      final moved = BlankUnitOps.move(units, 2, 0);
      expect(moved.first.tags, ['丙']);
    });

    test('拖到原地、越界下标都原样返回', () {
      final before = unitsOf(3);
      expect(BlankUnitOps.move(before, 1, 1), same(before));
      expect(BlankUnitOps.move(before, 0, 9), same(before));
      expect(BlankUnitOps.move(before, -1, 0), same(before));
    });
  });

  group('打标签', () {
    test('换掉指定分子的标签，别人不动', () {
      final units = BlankUnitOps.setTags(unitsOf(2), 1, ['厨房情景', '实拍']);
      expect(units[1].tags, ['厨房情景', '实拍']);
      expect(units[0].tags, isEmpty);
    });

    test('标签变了不该把它标成「过期」——这是手填的，不是打标模型产的', () {
      final units = BlankUnitOps.setTags(unitsOf(1), 0, ['实拍']);
      expect(units.single.tagsStale, isFalse);
    });
  });

  group('重排时间轴', () {
    test('挑了素材的分子按素材长度占位，后面的跟着挪', () {
      final laid = BlankUnitOps.relayout(
        unitsOf(3),
        durationOf: (i) => switch (i) { 0 => 5000, 2 => 3000, _ => null },
      );
      expect(laid[0].durationMs, 5000);
      expect(laid[1].durationMs, BlankUnitOps.placeholderMs, reason: '没挑的用占位');
      expect(laid[2].durationMs, 3000);
      expect(laid[0].startMs, 0);
      expect(laid[1].startMs, 5000);
      expect(laid[2].startMs, 5000 + BlankUnitOps.placeholderMs);
    });

    test('素材长度为 0 或负数时退回占位，不产生零宽格子', () {
      final laid =
          BlankUnitOps.relayout(unitsOf(2), durationOf: (i) => i == 0 ? 0 : -5);
      expect(laid.every((u) => u.durationMs == BlankUnitOps.placeholderMs),
          isTrue);
    });
  });

  group('已填时长统计', () {
    test('只统计挑过素材的，没挑的不算进去', () {
      // 全片时长绝不能把占位值算进去——那个数字是编的
      final stat = BlankUnitOps.filledStat(
        unitsOf(4),
        durationOf: (i) => i < 2 ? 4000 : null,
      );
      expect(stat.filledCount, 2);
      expect(stat.emptyCount, 2);
      expect(stat.filledMs, 8000);
    });

    test('一个都没挑时时长是 0，不是占位值之和', () {
      final stat =
          BlankUnitOps.filledStat(unitsOf(3), durationOf: (_) => null);
      expect(stat.filledMs, 0);
      expect(stat.emptyCount, 3);
    });

    test('全挑满了要能一眼看出来', () {
      final stat =
          BlankUnitOps.filledStat(unitsOf(2), durationOf: (_) => 1500);
      expect(stat.allFilled, isTrue);
      expect(stat.filledMs, 3000);
    });

    test('一个分子都没有时不算「全挑满」——那是空任务，不是完成', () {
      final stat = BlankUnitOps.filledStat(const [], durationOf: (_) => null);
      expect(stat.allFilled, isFalse);
    });
  });
}
