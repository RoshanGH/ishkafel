import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/features/picking/picking_controller.dart';

/// 切完分镜之后**必须能给某一镜挑素材**——不然整件事白做。
///
/// 数据上这个单元仍然挂着一条「整体替换」的候选（旧存档）或者已经落到
/// 镜头替换上（新切的），但那一条的角色是**底片**，不再和镜头替换互斥。
void main() {
  SemanticUnit pinned() => const SemanticUnit(
        uid: 'u1',
        index: 0,
        startMs: 0,
        endMs: 16300,
        transcript: '',
        hasSource: false,
        baseCandidateId: 7,
        shots: [
          Shot(startMs: 0, endMs: 3440),
          Shot(startMs: 3440, endMs: 9000),
          Shot(startMs: 9000, endMs: 16300),
        ],
      );

  SemanticUnit plain() => const SemanticUnit(
        uid: 'u1',
        index: 0,
        startMs: 0,
        endMs: 16300,
        transcript: '',
        hasSource: false,
      );

  PickingController of(SemanticUnit unit, UnitReplacement plan) =>
      PickingController(units: [unit], initial: [plan]);

  group('固定过底片', () {
    test('镜头替换不再被锁——切完就能挑', () {
      final c = of(pinned(), UnitReplacement.whole([7], previewId: 7));

      expect(c.canUsePerShot, isTrue);
      expect(c.perShotLocked, isFalse,
          reason: '那一条是底片，不是「顶替这一段」的候选');
    });

    test('底片那一档反过来锁死：要换底片走属性面板那条路', () {
      final c = of(pinned(), UnitReplacement.whole([7], previewId: 7));

      expect(c.wholeLockedByBase, isTrue,
          reason: '在这儿换掉，切好的镜头就全指向另一条素材的时间点');
    });

    test('切到镜头替换不提示「会清空已选候选」——底片记在单元上，丢不了', () {
      final c = of(pinned(), UnitReplacement.whole([7], previewId: 7));

      expect(
        c.discardsSelectionsWhenSwitchingTo(ReplacementMode.perShot),
        isFalse,
        reason: '照旧提示的话人会以为底片没了而不敢点',
      );
    });

    test('真的切过去之后，每一镜都能单独挑', () {
      final c = of(pinned(), UnitReplacement.whole([7], previewId: 7));
      c.setMode(ReplacementMode.perShot);
      c.selectShot(1);
      c.toggleCandidate(99);

      expect(c.currentReplacement.shotCandidateIds[1], [99]);
    });
  });

  group('没固定底片的照旧二选一', () {
    test('整体替换选了候选，镜头替换就锁着', () {
      final c = of(plain(), UnitReplacement.whole([7], previewId: 7));

      expect(c.perShotLocked, isTrue);
      expect(c.wholeLockedByBase, isFalse);
    });

    test('切换方式仍然要提示会清空', () {
      final c = of(plain(), UnitReplacement.whole([7], previewId: 7));

      expect(c.discardsSelectionsWhenSwitchingTo(ReplacementMode.perShot),
          isTrue);
    });
  });
}
