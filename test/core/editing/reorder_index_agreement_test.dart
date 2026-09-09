import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/audio/voice_plan.dart';
import 'package:ishkafel/core/editing/unit_reorder.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

/// **挪一个单元，按下标记的那几份必须落到同一个位置。**
///
/// 手改字幕已经不在这张表里了：它改成按单元的**身份**记
/// （[SemanticUnit.uid]），单元怎么排都还是它，一份都不用搬。
/// 剩下这三份是还没改完的。
///
/// 2026-09-08 真机，用户原话：「我给这个自定义台词语义单元选了一个镜头，
/// 然后我又把这个台词语义单元拉到后面……那个替换的镜头没有跟着 U2 走，
/// 它还留在 U1 里面。」
///
/// 查出来是**同一件事有两套算法**：
/// - 单元与替换方案：先 insert 再 remove——往后挪时落点少一格，
///   挪到相邻的下一位（to = from+1）**完全不动**
/// - 配音与配乐：按下标重映射，语义是对的
///
/// 两套一起跑，结果自然对不上。这里把「挪完之后第 i 个去了哪儿」钉死成
/// 一份，四份数据都拿它对照。
void main() {
  List<SemanticUnit> unitsOf(int n) => [
        for (var i = 0; i < n; i++)
          SemanticUnit(
              index: i,
              startMs: i * 1000,
              endMs: (i + 1) * 1000,
              transcript: 'U${i + 1}'),
      ];

  /// 参考实现：把第 from 个取出来，插到最终下标 to 上
  List<T> reference<T>(List<T> list, int from, int to) {
    final out = [...list];
    out.insert(to, out.removeAt(from));
    return out;
  }

  group('单元本身', () {
    test('往后挪一格：真的挪一格（曾经是完全不动）', () {
      final moved = moveUnit(unitsOf(4), from: 0, to: 1);

      expect(moved.map((u) => u.transcript).toList(),
          ['U2', 'U1', 'U3', 'U4'],
          reason: '先 insert 再 remove 的写法在 to == from+1 时是个空操作——'
              '人拖了一下，列表纹丝不动');
    });

    test('穷举所有 from/to：和参考实现一致', () {
      for (var n = 2; n <= 6; n++) {
        final base = unitsOf(n);
        for (var from = 0; from < n; from++) {
          for (var to = 0; to < n; to++) {
            if (from == to) continue;
            final got = moveUnit(base, from: from, to: to)
                .map((u) => u.transcript)
                .toList();
            final want = reference(base, from, to)
                .map((u) => u.transcript)
                .toList();
            expect(got, want, reason: 'n=$n from=$from to=$to');
          }
        }
      }
    });

    test('下标重新编号，和位置一致', () {
      final moved = moveUnit(unitsOf(4), from: 3, to: 1);

      expect(moved.map((u) => u.index).toList(), [0, 1, 2, 3]);
    });
  });

  group('三份数据落到同一个位置', () {
    /// 给第 [mark] 个单元挂上「可辨认的东西」，挪完之后看它们在不在同一格
    void check(int n, int from, int to, int mark) {
      final replacements = [
        for (var i = 0; i < n; i++)
          i == mark
              ? UnitReplacement.whole(const [999])
              : UnitReplacement.keepOriginal(),
      ];
      final voices = VoicePlan([
        VoiceAssignment(
            unitIndex: mark, voice: const VoiceRef(id: 'v', name: 'v')),
      ]);
      final bgm = BgmPlan([
        BgmSegment(
            startUnit: mark, endUnit: mark, materials: const [], fit: BgmFit.loop),
      ]);

      final movedUnits = moveUnit(unitsOf(n), from: from, to: to);
      final where = movedUnits.indexWhere((u) => u.transcript == 'U${mark + 1}');

      final r = remapReplacementsAfterMove(replacements,
          from: from, to: to, unitCount: n);
      expect(r.indexWhere((e) => e.wholeCandidateIds.isNotEmpty), where,
          reason: '替换方案没跟着单元走：n=$n from=$from to=$to mark=$mark');

      final v = remapVoicesAfterMove(voices, from: from, to: to);
      expect(v.assignments.single.unitIndex, where,
          reason: '配音没跟着走：n=$n from=$from to=$to mark=$mark');

      final b = remapBgmAfterMove(bgm, from: from, to: to);
      expect(b.plan.segments.single.startUnit, where,
          reason: '配乐没跟着走：n=$n from=$from to=$to mark=$mark');

    }

    test('穷举：任意规模、任意挪法、任意被标记的单元', () {
      for (var n = 2; n <= 5; n++) {
        for (var from = 0; from < n; from++) {
          for (var to = 0; to < n; to++) {
            if (from == to) continue;
            for (var mark = 0; mark < n; mark++) {
              check(n, from, to, mark);
            }
          }
        }
      }
    });
  });

  group('方案比单元少（刚加完单元还没挑素材）', () {
    test('补齐之后照样跟着走', () {
      // 5 个单元、4 条方案：第 5 个是刚加的，还没挑素材
      final replacements = [
        UnitReplacement.whole(const [999]),
        UnitReplacement.keepOriginal(),
        UnitReplacement.keepOriginal(),
        UnitReplacement.keepOriginal(),
      ];

      final r = remapReplacementsAfterMove(replacements,
          from: 0, to: 2, unitCount: 5);

      expect(r.length, 5);
      expect(r.indexWhere((e) => e.wholeCandidateIds.isNotEmpty), 2,
          reason: '把第 0 个挪到第 2 位，它挑的素材也该在第 2 位');
    });
  });
}
