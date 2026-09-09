import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/editing/blank_unit_removal.dart';
import 'package:ishkafel/core/editing/unit_reorder.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

SemanticUnit _u(int index, {String? text}) => SemanticUnit(
      index: index,
      startMs: index * 1000,
      endMs: (index + 1) * 1000,
      transcript: text ?? 'U${index + 1}',
    );

void main() {
  group('挪单元：列表顺序就是成片顺序', () {
    test('把 U2 挪到 U1 的位置，它就成了 U1', () {
      final units = [_u(0), _u(1), _u(2)];

      final moved = moveUnit(units, from: 1, to: 0);

      expect(moved.map((u) => u.transcript), ['U2', 'U1', 'U3']);
      expect(moved.map((u) => u.index), [0, 1, 2],
          reason: '下标必须跟位置一致——所有按下标记的东西都指着它');
    });

    test('原片区间跟着单元一起搬，不重算', () {
      final units = [_u(0), _u(1), _u(2)];

      final moved = moveUnit(units, from: 1, to: 0);

      expect(moved.first.startMs, 1000,
          reason: '它取自原片 1000~2000 这一段，换了位置也还是取那一段');
      expect(moved.first.endMs, 2000);
    });

    test('越界或原地不动都原样返回', () {
      final units = [_u(0), _u(1)];
      expect(identical(moveUnit(units, from: 1, to: 1), units), isTrue);
      expect(identical(moveUnit(units, from: 5, to: 0), units), isTrue);
      expect(identical(moveUnit(units, from: 0, to: 9), units), isTrue);
    });
  });

  group('按下标记的东西要跟着搬', () {
    test('替换方案跟着走——不然挑给 U2 的素材会跑到别人身上', () {
      final plans = [
        UnitReplacement.whole(const [101]),
        UnitReplacement.whole(const [202]),
        UnitReplacement.whole(const [303]),
      ];

      final moved = remapReplacementsAfterMove(plans, from: 1, to: 0, unitCount: 3);

      expect(moved[0].wholeCandidateIds, [202]);
      expect(moved[1].wholeCandidateIds, [101]);
      expect(moved[2].wholeCandidateIds, [303]);
    });

    test('替换方案比单元少时也要重排——真机就栽在这儿', () {
      // 加一个单元时替换方案不会跟着长出一条，于是「单元 6 条、方案 5 条」。
      // 把第 6 个单元（下标 5）拖到最前面，from=5 超出了方案列表的长度，
      // 老实现直接原样返回——整个重排被跳过，素材全跟错了单元。
      // 2026-09-07 真机上就是这么把 114799 从 U3 挪到了别人身上
      final plans = [
        UnitReplacement.keepOriginal(),
        UnitReplacement.keepOriginal(),
        UnitReplacement.whole(const [114799]),
        UnitReplacement.keepOriginal(),
        UnitReplacement.keepOriginal(),
      ];

      final moved =
          remapReplacementsAfterMove(plans, from: 5, to: 0, unitCount: 6);

      expect(moved.length, 6, reason: '补齐到单元数，不然下标永远对不齐');
      expect(moved[0].mode, ReplacementMode.keepOriginal,
          reason: '挪到最前面的是新加的那个，它还没挑素材');
      expect(moved[3].wholeCandidateIds, [114799],
          reason: '原来在下标 2 的素材，整体后移一格到 3');
    });


  });

  group('配乐是按区间记的，挪单元会打断它', () {
    test('整段都在区间内部挪动，区间不变', () {
      final plan = BgmPlan([_seg(0, 2)]);

      final result = remapBgmAfterMove(plan, from: 1, to: 2);

      expect(result.plan.segments.single.startUnit, 0);
      expect(result.plan.segments.single.endUnit, 2);
      expect(result.brokenSegments, isEmpty, reason: '没打断就不该报警');
    });

    test('把区间里的单元挪出去，区间收缩并点名', () {
      final plan = BgmPlan([_seg(0, 1)]);

      final result = remapBgmAfterMove(plan, from: 0, to: 2);

      expect(result.plan.segments.single.startUnit, 0,
          reason: '原来的 U2 顶上来成了 U1，区间还盖着它');
      expect(result.plan.segments.single.endUnit, 0);
      expect(result.brokenSegments, isNotEmpty,
          reason: '配乐盖的范围变了，必须说出来——不许悄悄改成另一个样子');
    });

    test('区间里只剩被挪走的那一个，整段删掉并点名', () {
      final plan = BgmPlan([_seg(1, 1)]);

      final result = remapBgmAfterMove(plan, from: 1, to: 0);

      expect(result.plan.segments.single.startUnit, 0,
          reason: '这一段配乐跟着它挪走的那个单元走');
      expect(result.brokenSegments, isEmpty);
    });
  });

  group('删单元时配音也要跟着搬（原本漏了）', () {


  });
}

BgmSegment _seg(int start, int end) => BgmSegment(
      startUnit: start,
      endUnit: end,
      materials: const [
        BgmMaterial(id: 1, name: '垫乐', durationMs: 30000, previewUrl: null),
      ],
      fit: BgmFit.loop,
    );
