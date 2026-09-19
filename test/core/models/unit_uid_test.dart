import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/segmentation_edit_ops.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/models/unit_uid.dart';

/// 台词语义单元的**身份**。产品负责人 2026-09-09：
///
/// > 这个台词语义单元应该有一个自己的编号，但不是 U1 U2 U3，因为它位置排序
/// > 是有可能会变的。它这个编号下的所有数据都是跟着这个编号走。
///
/// 位置（U1/U2/U3）是成片顺序，人一拖就变；身份永不变。挂在单元上的东西
/// ——挑好的素材、音色、配乐、手改字幕、生成的配音文件——全按身份记。
void main() {
  SemanticUnit unit(int i, int a, int b, {String uid = ''}) => SemanticUnit(
        uid: uid,
        index: i,
        startMs: a,
        endMs: b,
        transcript: 'u$i',
        shots: [Shot(startMs: a, endMs: b)],
      );

  group('补发身份', () {
    test('老存档没有身份：补上，而且互不相同', () {
      final out = ensureUnitUids([unit(0, 0, 1000), unit(1, 1000, 2000)]);

      expect(out.every((u) => isUnitUid(u.uid)), isTrue);
      expect(out[0].uid, isNot(out[1].uid));
    });

    test('撞号的换掉——两个单元共用一个身份，东西会同时落到两格上', () {
      final out = ensureUnitUids([
        unit(0, 0, 1000, uid: 'same'),
        unit(1, 1000, 2000, uid: 'same'),
      ]);

      expect(out[0].uid, 'same', reason: '先来的留用');
      expect(out[1].uid, isNot('same'));
    });

    test('本来就齐的原样返回同一个对象——别把 undo 栈灌满', () {
      final ok = [unit(0, 0, 1000, uid: 'a'), unit(1, 1000, 2000, uid: 'b')];

      expect(identical(ensureUnitUids(ok), ok), isTrue);
    });
  });

  group('身份跟着单元一辈子', () {
    test('改边界、改台词、重新打标都不动它', () {
      final u = unit(0, 0, 1000, uid: 'keep');

      expect(u.copyWith(endMs: 2000).uid, 'keep');
      expect(u.copyWith(transcript: '换一句').uid, 'keep');
      expect(u.copyWith(tags: const ['促单'], tagsStale: true).uid, 'keep');
    });

    test('存盘再读回来还是它', () {
      final u = unit(0, 0, 1000, uid: 'keep');

      expect(SemanticUnit.fromJson(u.toJson()).uid, 'keep');
    });

    test('老存档读出来是空身份，等着补发', () {
      final raw = unit(0, 0, 1000).toJson()..remove('uid');

      expect(SemanticUnit.fromJson(raw).uid, '');
    });
  });

  group('拆分：左边留用，右边发新的', () {
    test('产品上「左边还是原来那一句」，东西该留在左边', () {
      final units = ensureUnitUids([unit(0, 0, 2000)]);
      final before = units.single.uid;

      final out = SegmentationEditOps.splitUnitAt(units, 0, 1000,
          fps: 30, sentences: const [])!;

      expect(out, hasLength(2));
      expect(out[0].uid, before, reason: '左边留用原身份');
      expect(isUnitUid(out[1].uid), isTrue);
      expect(out[1].uid, isNot(before), reason: '共用一个身份的话，'
          '挑给它的素材会同时落到两格上');
    });
  });

  group('手动加的单元也有身份', () {
    test('有原片的任务：appendUnit', () {
      final out = SegmentationEditOps.appendUnit(
          ensureUnitUids([unit(0, 0, 1000)]),
          fps: 30);

      expect(isUnitUid(out.last.uid), isTrue);
      expect(out.last.uid, isNot(out.first.uid));
    });
  });

  /// 读档补发专用版：**同一份数据推两次必须完全一样**，不能像
  /// [ensureUnitUids] 那样掷随机数——`findById`/`findAll` 是两次独立的
  /// 解析，TaskMutation 靠 uid 在它们之间把同一个单元重新认出来，
  /// 推出不一样的值就永远对不上号（2026-09-17 真机复审揪出来的洞）。
  group('读档补发身份：确定性推导，不掷随机数', () {
    test('同一份盘上数据（同一个 taskId）连读两次，uid 必须完全一样', () {
      final raw = [unit(0, 0, 1000), unit(1, 1000, 2000)];

      final first = ensureUnitUidsDeterministic('t1', raw);
      final second = ensureUnitUidsDeterministic('t1', raw);

      expect(first.map((u) => u.uid).toList(), second.map((u) => u.uid).toList(),
          reason: 'findById 和 findAll 各自独立解析同一份磁盘数据，'
              '推出来的身份必须一样，否则 TaskMutation 靠 uid 重新定位'
              '单元的每一处都会落空');
    });

    test('taskId 不同，推出来的 uid 也不同——跨任务不能撞', () {
      final raw = [unit(0, 0, 1000)];

      final a = ensureUnitUidsDeterministic('taskA', raw);
      final b = ensureUnitUidsDeterministic('taskB', raw);

      expect(a.single.uid, isNot(b.single.uid));
    });

    test('同一个任务内，起止一样但下标不同的单元不会撞号', () {
      // 两条空白任务的占位分子起止经常是同一个数（比如都是 0~10000）——
      // 光靠内容推不出区分度，index 顶上
      final raw = [unit(0, 0, 1000), unit(1, 0, 1000)];

      final out = ensureUnitUidsDeterministic('t1', raw);

      expect(out[0].uid, isNot(out[1].uid));
    });

    test('已经有身份的不动——读档补发不改已经建立好的身份', () {
      final ok = [unit(0, 0, 1000, uid: 'kept-uid')];

      final out = ensureUnitUidsDeterministic('t1', ok);

      expect(out.single.uid, 'kept-uid');
    });

    test('一个都不用补时原样返回同一个对象', () {
      final ok = [unit(0, 0, 1000, uid: 'a'), unit(1, 1000, 2000, uid: 'b')];

      expect(identical(ensureUnitUidsDeterministic('t1', ok), ok), isTrue);
    });
  });
}
