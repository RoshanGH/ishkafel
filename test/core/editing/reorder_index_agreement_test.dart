import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/voice_plan.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/models/unit_uid.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/core/subtitle/subtitle_overlay.dart';
import 'package:ishkafel/core/subtitle/subtitle_track.dart';

/// **挪一个单元，挂在它下面的每一份数据都还挂在它身上。**
///
/// 这条线的历史：单元的「身份」曾经就是它在列表里的位置，于是每挪一次、
/// 每删一次都要人工把四份数据搬一遍（替换方案、配音、配乐、手改字幕）。
/// 半年里漏搬过三次，每次都是「不报错，只有把片子导出来看一遍才发现」：
///
/// - 2026-09-07 配音：删掉 U2 之后，本该念 U3 的配音跑到 U2 身上
/// - 2026-09-08 替换方案：挪动之后挑好的素材留在原来那一格
/// - 2026-09-09 手改字幕：从头到尾就没搬过
///
/// 产品负责人：「这个台词语义单元应该有一个自己的编号，但不是 U1 U2 U3，
/// 因为它位置排序是有可能会变的。它这个编号下的所有数据都是跟着这个编号走。」
///
/// 所以现在**一份都不用搬**——这条测试盯的就是这件事：任意规模、任意挪法、
/// 任意被标记的单元，挪完之后每一份数据都还认得那个单元。
void main() {
  List<SemanticUnit> unitsOf(int n) => ensureUnitUids([
        for (var i = 0; i < n; i++)
          SemanticUnit(
            index: i,
            startMs: i * 1000,
            endMs: (i + 1) * 1000,
            transcript: 'U${i + 1}',
            shots: [Shot(startMs: i * 1000, endMs: (i + 1) * 1000)],
          ),
      ]);

  /// 给第 [mark] 个单元挂上四样可辨认的东西，挪完之后看它们还在不在它身上
  void check(int n, int from, int to, int mark) {
    final units = unitsOf(n);
    final marked = units[mark].uid;

    final task = RenewTask(
      id: 't',
      name: 'n',
      sourcePath: '/v/a.mp4',
      status: RenewTaskStatus.ready,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      units: units,
      replacementsByUid: {marked: UnitReplacement.whole(const [999])},
      voices: VoicePlan.empty
          .assign([marked], const VoiceRef(id: 'v', name: 'v')),
      subtitleTrack: const SubtitleTrack.empty().withLines(
          SubtitleSlot(unitUid: marked, shotIndex: 0),
          const [SubtitleLine(startMs: 0, endMs: 800, text: '手改过的')]),
    );

    // 挪：列表顺序就是成片顺序，单元自己的身份一个字都不变
    final moved = [...units];
    moved.insert(to, moved.removeAt(from));
    final after = task.copyWith(units: moved);
    final where = moved.indexWhere((u) => u.uid == marked);

    final why = 'n=$n from=$from to=$to mark=$mark';
    expect(after.replacementsFor(moved)[where].wholeCandidateIds, [999],
        reason: '替换方案没跟着单元走：$why');
    expect(after.voices.voiceOf(moved[where].uid)?.id, 'v',
        reason: '配音没跟着走：$why');
    expect(
        after.subtitleTrack
            .linesOf(SubtitleSlot(unitUid: moved[where].uid, shotIndex: 0))
            ?.single
            .text,
        '手改过的',
        reason: '手改字幕没跟着走：$why');
    // 别人身上不能凭空多出东西来
    for (var i = 0; i < moved.length; i++) {
      if (i == where) continue;
      expect(after.replacementsFor(moved)[i].mode,
          ReplacementMode.keepOriginal,
          reason: '第 $i 格凭空多出一份方案：$why');
    }
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

  test('删掉别的单元，它身上的东西一份不少', () {
    final units = unitsOf(4);
    final marked = units[2].uid;
    final task = RenewTask(
      id: 't',
      name: 'n',
      sourcePath: '/v/a.mp4',
      status: RenewTaskStatus.ready,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      units: units,
      replacementsByUid: {marked: UnitReplacement.whole(const [999])},
      voices: VoicePlan.empty
          .assign([marked], const VoiceRef(id: 'v', name: 'v')),
    );

    // 删掉第 0 个
    final left = [...units]..removeAt(0);
    final after = task.copyWith(units: left);

    expect(after.replacementsFor(left)[1].wholeCandidateIds, [999],
        reason: '删掉前面一个之后，它整体前移一格，方案要跟着它');
    expect(after.voices.voiceOf(marked)?.id, 'v');
  });
}
