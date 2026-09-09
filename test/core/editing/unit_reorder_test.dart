import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/editing/unit_reorder.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';

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
