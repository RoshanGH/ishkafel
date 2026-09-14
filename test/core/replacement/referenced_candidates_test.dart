import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/core/replacement/unit_base.dart';

/// 「这条素材还有没有人用」少算一处，那条素材就会被当成孤儿清掉。
///
/// 2026-09-15 真机走查撞到的：切完分镜再给一镜挑素材，方案从整体替换落到
/// 镜头替换，底片就不在任何 replacement 里了。收敛「已选素材」时把它判成
/// 没人引用、连记录带首帧图一起清掉，预览找不到底片路径——**整段变黑**，
/// 而哪儿都不报错。
void main() {
  SemanticUnit pinned() => const SemanticUnit(
        uid: 'u0',
        index: 0,
        startMs: 0,
        endMs: 16300,
        transcript: '',
        hasSource: false,
        baseCandidateId: 114799,
        shots: [
          Shot(startMs: 0, endMs: 8000),
          Shot(startMs: 8000, endMs: 16300),
        ],
      );

  test('整体替换的候选算', () {
    expect(
      referencedCandidateIds(
          [pinned()], [UnitReplacement.whole([7])]),
      containsAll([7]),
    );
  });

  test('镜头替换的候选算', () {
    expect(
      referencedCandidateIds([
        pinned()
      ], [
        UnitReplacement.perShot({
          1: [106868]
        })
      ]),
      contains(106868),
    );
  });

  test('**底片也算**——它记在单元身上，不在方案里', () {
    final ids = referencedCandidateIds([
      pinned()
    ], [
      UnitReplacement.perShot({
        1: [106868]
      })
    ]);

    expect(ids, containsAll([114799, 106868]),
        reason: '漏掉底片，那条素材会被当孤儿清掉，预览整段变黑');
  });

  test('方案里一条都没选、只有底片：底片仍然算', () {
    expect(
      referencedCandidateIds([pinned()], [UnitReplacement.keepOriginal()]),
      {114799},
    );
  });

  test('没固定过底片的单元不凭空加东西', () {
    const plain = SemanticUnit(
        index: 0, startMs: 0, endMs: 4000, transcript: '一句台词');

    expect(referencedCandidateIds([plain], [UnitReplacement.keepOriginal()]),
        isEmpty);
  });
}
