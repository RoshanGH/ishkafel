import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/review_apply.dart';
import 'package:ishkafel/core/review/review_receipt.dart';

/// Agent 替人剔除候选时的校验。
///
/// 与界面确认走的 [applyReviewDecisions] 刻意不同：那一条对不上的位置直接
/// 忽略（回执少一条不能变成隐式剔除），这里必须**整批拒绝并点名**——
/// 人说「删掉第 3 条」，Agent 编号写错却静默成功，人会以为删了。
void main() {
  const items = [
    ReviewItem(unit: 0, shot: null, material: 100),
    ReviewItem(unit: 0, shot: null, material: 101),
    ReviewItem(unit: 1, shot: 2, material: 200),
  ];

  group('validateReviewSubmission', () {
    test('决定都命中现存候选就没有问题', () {
      final issues = validateReviewSubmission(
        items: items,
        decisions: const [
          ReviewDecision(unit: 0, shot: null, material: 100, keep: false),
          ReviewDecision(unit: 1, shot: 2, material: 200, keep: true),
        ],
      );
      expect(issues, isEmpty);
    });

    test('引用了不存在的候选：整批拒绝并说清是哪一条', () {
      final issues = validateReviewSubmission(
        items: items,
        decisions: const [
          ReviewDecision(unit: 0, shot: null, material: 100, keep: false),
          ReviewDecision(unit: 9, shot: null, material: 999, keep: false),
        ],
      );
      expect(issues, hasLength(1));
      expect(issues.single, contains('999'));
      expect(issues.single, contains('第 2 条'));
    });

    test('镜头号对不上也算不存在——不能落到别的位置上去', () {
      final issues = validateReviewSubmission(
        items: items,
        decisions: const [
          ReviewDecision(unit: 1, shot: 5, material: 200, keep: false),
        ],
      );
      expect(issues, hasLength(1));
    });

    test('同一个位置前后说法矛盾就拒绝', () {
      final issues = validateReviewSubmission(
        items: items,
        decisions: const [
          ReviewDecision(unit: 0, shot: null, material: 100, keep: false),
          ReviewDecision(unit: 0, shot: null, material: 100, keep: true),
        ],
      );
      expect(issues, hasLength(1));
      expect(issues.single, contains('不一致'));
    });

    test('一条决定都没有：不当成「什么都不改」，直接拒', () {
      expect(validateReviewSubmission(items: items, decisions: const []),
          hasLength(1));
    });

    test('多个问题一次全报出来，不是报一条改一条', () {
      final issues = validateReviewSubmission(
        items: items,
        decisions: const [
          ReviewDecision(unit: 9, shot: null, material: 999, keep: false),
          ReviewDecision(unit: 8, shot: null, material: 888, keep: false),
        ],
      );
      expect(issues, hasLength(2));
    });
  });

  group('parseReviewItems', () {
    test('unit:shot:material，shot 用 - 表示整体替换的候选', () {
      final parsed = parseReviewItems('0:-:100, 1:2:200', keep: false);
      expect(parsed.issues, isEmpty);
      expect(parsed.decisions, hasLength(2));
      expect(parsed.decisions.first.unit, 0);
      expect(parsed.decisions.first.shot, isNull);
      expect(parsed.decisions.first.material, 100);
      expect(parsed.decisions.first.keep, isFalse);
      expect(parsed.decisions.last.shot, 2);
    });

    test('keep: true 时解析出来的是「恢复」', () {
      final parsed = parseReviewItems('0:-:100', keep: true);
      expect(parsed.decisions.single.keep, isTrue);
    });

    test('格式不对就点名那一段，不猜', () {
      final parsed = parseReviewItems('0:-:100, 乱写', keep: false);
      expect(parsed.issues, hasLength(1));
      expect(parsed.issues.single, contains('乱写'));
    });

    test('空串不是「全删」，是没给', () {
      expect(parseReviewItems('  ', keep: false).issues, hasLength(1));
    });
  });
}
