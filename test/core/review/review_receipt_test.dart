import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/core/review/review_receipt.dart';

/// 人审核 Agent 挑的候选：软件负责**固定的回执格式**与**确定的应用规则**。
///
/// Agent 现造审核页的问题就在这两处：回执格式每次现编、剔除逻辑每次现写。
/// 这里把它们钉成软件的一部分——任何 Agent 走到审核这一步，拿到的都是
/// 同一份契约。
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

  group('回执落盘', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('review_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('存取往返不丢东西', () {
      final receipt = ReviewReceipt(
        reviewedAt: DateTime.utc(2026, 8, 17, 10, 30),
        decisions: const [
          ReviewDecision(unit: 0, shot: null, material: 101, keep: true),
          ReviewDecision(unit: 2, shot: 5, material: 202, keep: false),
        ],
      );
      saveReviewReceipt(dir, 't1', receipt);
      final loaded = readReviewReceipt(dir, 't1')!;

      expect(loaded.reviewedAt, receipt.reviewedAt);
      expect(loaded.decisions.length, 2);
      expect(loaded.decisions[1].keep, isFalse);
      expect(loaded.decisions[1].shot, 5);
    });

    test('没审核过返回 null，文件坏了也返回 null 而不是炸', () {
      expect(readReviewReceipt(dir, '没有'), isNull);
      File('${dir.path}/reviews/bad.json')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('不是 json');
      expect(readReviewReceipt(dir, 'bad'), isNull);
    });
  });
}
