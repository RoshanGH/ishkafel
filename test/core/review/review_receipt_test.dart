import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/core/review/review_receipt.dart';

/// 人审核挑好的候选：软件负责**确定的剔除规则**。审核完一切回到主流程，
/// 任务里的方案就是最终结果——没有回执这层中间产物。
void main() {
  group('收集待审位置', () {
    test('整体替换与镜头替换的候选逐条列出，保留原片的不列', () {
      final items = collectReviewItems([
        UnitReplacement.whole(const [101, 102]),
        UnitReplacement.keepOriginal(),
        UnitReplacement.perShot(const {
          2: [201],
          5: [202, 203],
        }),
      ]);

      expect(items.map((i) => (i.unit, i.shot, i.material)), [
        (0, null, 101),
        (0, null, 102),
        (2, 2, 201),
        (2, 5, 202),
        (2, 5, 203),
      ]);
    });

    test('一条候选都没挑时为空——上层据此显示「没有可审核的」', () {
      expect(collectReviewItems([UnitReplacement.keepOriginal()]), isEmpty);
    });
  });

  group('应用决定', () {
    test('剔除的候选从方案里拿掉，保留的原样', () {
      final next = applyReviewDecisions(
        [
          UnitReplacement.whole(const [101, 102]),
          UnitReplacement.perShot(const {
            0: [201, 202],
          }),
        ],
        [
          const ReviewDecision(unit: 0, shot: null, material: 101, keep: false),
          const ReviewDecision(unit: 1, shot: 0, material: 202, keep: false),
        ],
      );

      expect(next[0].wholeCandidateIds, [102]);
      expect(next[1].shotCandidateIds[0], [201]);
    });

    test('没被提到的候选一律保留——回执少一条不能变成隐式剔除', () {
      final next = applyReviewDecisions(
        [
          UnitReplacement.whole(const [101, 102]),
        ],
        [
          const ReviewDecision(unit: 0, shot: null, material: 101, keep: false),
        ],
      );
      expect(next[0].wholeCandidateIds, [102]);
    });

    test('某个位置全被剔除也如实执行——那一段回到保留原片', () {
      final next = applyReviewDecisions(
        [
          UnitReplacement.whole(const [101]),
        ],
        [
          const ReviewDecision(unit: 0, shot: null, material: 101, keep: false),
        ],
      );
      expect(next[0].wholeCandidateIds, isEmpty);
    });

    test('决定引用了不存在的位置时忽略该条，不炸也不误伤别人', () {
      final before = [
        UnitReplacement.whole(const [101]),
      ];
      final next = applyReviewDecisions(before, [
        const ReviewDecision(unit: 9, shot: null, material: 101, keep: false),
      ]);
      expect(next[0].wholeCandidateIds, [101]);
    });
  });

}
