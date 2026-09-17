import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/tag_merge.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';

Shot _shot(int start, int end, {List<String> tags = const []}) =>
    Shot(startMs: start, endMs: end, tags: tags);

/// [uid] 缺省按 index 发一个稳定的身份。**真实数据上一定有**：
/// 读档走 `RenewTask.fromJson` → `ensureUnitUids`，编辑器收下单元时再补一次
SemanticUnit _unit(
  int index,
  int start,
  int end, {
  String? uid,
  List<String> tags = const [],
  List<Shot> shots = const [],
  bool tagsStale = false,
}) =>
    SemanticUnit(
      uid: uid ?? 'uid$index',
      index: index,
      startMs: start,
      endMs: end,
      transcript: 't$index',
      tags: tags,
      tagsStale: tagsStale,
      shots: shots,
    );

void main() {
  group('打标结果合并回当前单元', () {
    test('边界没变就把标签补上', () {
      final current = [
        _unit(0, 0, 1000, shots: [_shot(0, 500)]),
      ];
      final tagged = [
        _unit(0, 0, 1000,
            tags: ['促单'], shots: [_shot(0, 500, tags: ['实拍'])]),
      ];

      final merged = mergeTagsInto(current, tagged);

      expect(merged.single.tags, ['促单']);
      expect(merged.single.shots.single.tags, ['实拍']);
    });

    test('用户在打标期间拖过边界的单元，不安旧标签', () {
      // 打标要跑总时长七成，这七成里人就坐在工作台改切分
      final current = [_unit(0, 0, 1200)];
      final tagged = [_unit(0, 0, 1000, tags: ['促单'])];

      final merged = mergeTagsInto(current, tagged);

      expect(merged.single.tags, isEmpty,
          reason: '这份标签是照着 0~1000 打的，安到 0~1200 上就是错的');
      expect(merged.single.endMs, 1200, reason: '用户的改动必须原样保留');
    });

    test('单元没动但镜头动了，只跳过那个镜头', () {
      final current = [
        _unit(0, 0, 1000, shots: [_shot(0, 500), _shot(500, 800)]),
      ];
      final tagged = [
        _unit(0, 0, 1000, tags: ['促单'], shots: [
          _shot(0, 500, tags: ['实拍']),
          _shot(500, 1000, tags: ['口播']),
        ]),
      ];

      final merged = mergeTagsInto(current, tagged);

      expect(merged.single.tags, ['促单']);
      expect(merged.single.shots.first.tags, ['实拍']);
      expect(merged.single.shots.last.tags, isEmpty,
          reason: '这个镜头的边界被改过，旧标签不作数');
    });

    test('当前单元已有标签就不覆盖（用户或重新打标写的更新）', () {
      final current = [_unit(0, 0, 1000, tags: ['人工改过'])];
      final tagged = [_unit(0, 0, 1000, tags: ['促单'])];

      expect(mergeTagsInto(current, tagged).single.tags, ['人工改过']);
    });

    test('数量对不上也不会崩，能配上的照常合并', () {
      final current = [_unit(0, 0, 1000), _unit(1, 1000, 2000)];
      final tagged = [_unit(0, 0, 1000, tags: ['促单'])];

      final merged = mergeTagsInto(current, tagged);

      expect(merged.first.tags, ['促单']);
      expect(merged.last.tags, isEmpty);
    });

    test('没有标签可合并时原样返回入参本身（调用方靠它避免灌满 undo 栈）', () {
      final current = [_unit(0, 0, 1000, tags: ['促单'])];
      final tagged = [_unit(0, 0, 1000, tags: ['促单'])];

      expect(identical(mergeTagsInto(current, tagged), current), isTrue);
    });

    test('原列表不被改动（合并出的是新列表）', () {
      final current = [_unit(0, 0, 1000)];
      final tagged = [_unit(0, 0, 1000, tags: ['促单'])];

      mergeTagsInto(current, tagged);

      expect(current.single.tags, isEmpty);
    });
  });

  group('配对按身份，不是按下标', () {
    // 产品负责人 2026-09-16（真机）：「我新添加的一个测试单元，拉到第一位，
    // 我还没有做任何操作，它为什么就有标签了？」——打标那七成时间里人就在
    // 工作台里加单元、拖顺序，下标早就不是发起打标时那一套了
    test('人在打标期间拖了顺序：标签跟着单元走，不跟着位置走', () {
      final a = _unit(0, 0, 1000, uid: 'aaa');
      final b = _unit(1, 1000, 2000, uid: 'bbb');
      // 打标结果是照着「A 在前」打的
      final tagged = [
        _unit(0, 0, 1000, uid: 'aaa', tags: ['痛点']),
        _unit(1, 1000, 2000, uid: 'bbb', tags: ['促单']),
      ];
      // 而人已经把 B 拖到了最前面
      final current = [b.copyWith(index: 0), a.copyWith(index: 1)];

      final merged = mergeTagsInto(current, tagged);

      expect(merged[0].uid, 'bbb');
      expect(merged[0].tags, ['促单'], reason: 'B 的标签该落在 B 身上');
      expect(merged[1].uid, 'aaa');
      expect(merged[1].tags, ['痛点']);
    });

    test('新加进来的单元不在这份结果里，一个标签都不给它', () {
      final tagged = [_unit(0, 0, 1000, uid: 'aaa', tags: ['痛点'])];
      // 人加了个空单元并拖到最前
      final current = [
        _unit(0, 2000, 12000, uid: 'new'),
        _unit(1, 0, 1000, uid: 'aaa'),
      ];

      final merged = mergeTagsInto(current, tagged);

      expect(merged[0].tags, isEmpty, reason: '它压根没参与这一轮打标');
      expect(merged[1].tags, ['痛点']);
    });
  });

  /// `unitTagsChanged` 是调用方（apply_command.dart 的 units.tag.auto）
  /// 拿来判定「这个单元这一笔真的被打了标吗」的公开判据——跟
  /// `mergeTagsInto` 自己内部判定「要不要真的去动界面」必须是同一条规矩，
  /// 不能各算各的（2026-09-18 真机复审：单独拷贝一份会漏报"只改了镜头
  /// 标签"的单元）
  group('unitTagsChanged：调用方拿它判定这个单元这一笔真的变了没有', () {
    test('单元级标签没变，但镜头标签是这次填上的——算变了', () {
      final before = _unit(0, 0, 1000,
          tags: ['人工改过'], shots: [_shot(0, 500)]); // 单元已有人手打的标签
      final tagged = [
        _unit(0, 0, 1000, tags: ['促单'], shots: [_shot(0, 500, tags: ['实拍'])]),
      ];

      final after = mergeTagsInto([before], tagged).single;

      // 单元级标签确实没被覆盖（人工改过的不被打标结果盖掉）
      expect(after.tags, ['人工改过']);
      // 但镜头标签从空变成了 ['实拍']——这个单元真的变了
      expect(after.shots.single.tags, ['实拍']);
      expect(unitTagsChanged(before, after), isTrue,
          reason: '只看单元级 tags 会漏报——镜头标签才是这次真正被打上的');
    });

    test('单元级和镜头级都没变——不算变', () {
      final u = _unit(0, 0, 1000, tags: ['a'], shots: [_shot(0, 500, tags: ['b'])]);
      // copyWith 即使值没变也会造一个新对象，identical 在这里靠不住
      final copy = u.copyWith(tags: ['a']);

      expect(identical(u, copy), isFalse,
          reason: '这条断言本身就是在证明不能用 identical 判断有没有变');
      expect(unitTagsChanged(u, copy), isFalse);
    });

    test('单元级标签变了——算变', () {
      final before = _unit(0, 0, 1000, tags: const []);
      final after = _unit(0, 0, 1000, tags: ['促单']);

      expect(unitTagsChanged(before, after), isTrue);
    });
  });
}
