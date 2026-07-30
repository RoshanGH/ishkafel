import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/editing/segmentation_editor_controller.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';

const fps = 30.0;

List<SemanticUnit> fixture() => const [
      SemanticUnit(index: 0, startMs: 0, endMs: 6000, transcript: '第一段台词。', shots: [
        Shot(startMs: 0, endMs: 3000),
        Shot(startMs: 3000, endMs: 6000),
      ]),
      SemanticUnit(index: 1, startMs: 6000, endMs: 12000, transcript: '第二段台词。', shots: [
        Shot(startMs: 6000, endMs: 9000),
        Shot(startMs: 9000, endMs: 12000),
      ]),
    ];

const sentences = [
  AsrSentence(startMs: 0, endMs: 2900, text: '第一句。'),
  AsrSentence(startMs: 3100, endMs: 5900, text: '第二句。'),
  AsrSentence(startMs: 6100, endMs: 11900, text: '第三句。'),
];

SegmentationEditorController buildController() => SegmentationEditorController(
      initialUnits: fixture(),
      durationMs: 12000,
      fps: fps,
      sentences: sentences,
    );

// 3 单元夹具：用于验证合并后 selection 重映射（合并只影响相邻两单元，
// 需要第三个单元确认索引不是巧合对齐）
List<SemanticUnit> fixture3() => const [
      SemanticUnit(index: 0, startMs: 0, endMs: 4000, transcript: 'A', shots: [
        Shot(startMs: 0, endMs: 2000),
        Shot(startMs: 2000, endMs: 4000),
      ]),
      SemanticUnit(index: 1, startMs: 4000, endMs: 8000, transcript: 'B', shots: [
        Shot(startMs: 4000, endMs: 6000),
        Shot(startMs: 6000, endMs: 8000),
      ]),
      SemanticUnit(index: 2, startMs: 8000, endMs: 12000, transcript: 'C', shots: [
        Shot(startMs: 8000, endMs: 10000),
        Shot(startMs: 10000, endMs: 12000),
      ]),
    ];

SegmentationEditorController buildController3() => SegmentationEditorController(
      initialUnits: fixture3(),
      durationMs: 12000,
      fps: fps,
      sentences: const [],
    );

void main() {
  test('操作成功：推入 undo 栈、canUndo 为 true、notify 一次、返回 true', () {
    final c = buildController();
    var notifyCount = 0;
    c.addListener(() => notifyCount++);

    final ok = c.moveUnitBoundary(0, 7000);

    expect(ok, true);
    expect(c.units[0].endMs, 7000);
    expect(c.canUndo, true);
    expect(c.canRedo, false);
    expect(notifyCount, 1);
  });

  test('非法操作：不入栈、不 notify、返回 false', () {
    final c = buildController();
    var notifyCount = 0;
    c.addListener(() => notifyCount++);

    // 索引 1 是末尾边界（units 长度为 2），moveUnitBoundary 要求 i+1 < length
    final ok = c.moveUnitBoundary(1, 7000);

    expect(ok, false);
    expect(c.canUndo, false);
    expect(notifyCount, 0);
    expect(c.units, fixture());
  });

  test('undo 还原、redo 恢复', () {
    final c = buildController();
    c.moveUnitBoundary(0, 7000);
    expect(c.units[0].endMs, 7000);

    c.undo();
    expect(c.units, fixture());
    expect(c.canUndo, false);
    expect(c.canRedo, true);

    c.redo();
    expect(c.units[0].endMs, 7000);
    expect(c.canUndo, true);
    expect(c.canRedo, false);
  });

  test('新操作会清空 redo 栈', () {
    final c = buildController();
    c.moveUnitBoundary(0, 7000);
    c.undo();
    expect(c.canRedo, true);

    c.moveUnitBoundary(0, 8000);
    expect(c.canRedo, false);
  });

  test('dirty 语义：相对 initialUnits 是否有改动', () {
    final c = buildController();
    expect(c.dirty, false);

    c.moveUnitBoundary(0, 7000);
    expect(c.dirty, true);

    c.undo();
    expect(c.dirty, false);
  });

  group('splitSelectedAt', () {
    test('选中单元 → 走 splitUnitAt', () {
      final c = buildController();
      c.select(const EditorSelection.unit(0));

      final ok = c.splitSelectedAt(3000);

      expect(ok, true);
      expect(c.units.length, 3);
      expect(c.units[0].endMs, 3000);
      expect(c.units[0].transcript, '第一句。');
    });

    test('选中镜头 → 走 splitShotAt', () {
      final c = buildController();
      c.select(const EditorSelection.shot(0, 0));

      final ok = c.splitSelectedAt(1500);

      expect(ok, true);
      expect(c.units[0].shots.length, 3);
      expect(c.units[0].shots[0].endMs, 1500);
      // 镜头拆分不影响单元边界
      expect(c.units[0].startMs, 0);
      expect(c.units[0].endMs, 6000);
    });

    test('无选中 → 返回 false', () {
      final c = buildController();
      expect(c.splitSelectedAt(3000), false);
    });
  });

  group('mergeSelectedWithPrevious', () {
    test('选中单元 → 走 mergeUnitWithPrevious', () {
      final c = buildController();
      c.select(const EditorSelection.unit(1));

      final ok = c.mergeSelectedWithPrevious();

      expect(ok, true);
      expect(c.units.length, 1);
      expect(c.units.single.transcript, '第一段台词。第二段台词。');
    });

    test('选中镜头 → 走 mergeShotWithPrevious', () {
      final c = buildController();
      c.select(const EditorSelection.shot(0, 1));

      final ok = c.mergeSelectedWithPrevious();

      expect(ok, true);
      expect(c.units[0].shots.length, 1);
    });

    test('无选中 → 返回 false', () {
      final c = buildController();
      expect(c.mergeSelectedWithPrevious(), false);
    });
  });

  group('nudgeSelectedEdge', () {
    test('选中单元，startEdge=true，+1 帧：与前一单元边界前移一帧（30fps→33ms）', () {
      final c = buildController();
      c.select(const EditorSelection.unit(1));

      final ok = c.nudgeSelectedEdge(startEdge: true, frames: 1);

      expect(ok, true);
      // 单元 1 的 start 边界即 moveUnitBoundary(0, ...)，当前 6000ms，+1 帧(33ms)→6033ms
      expect(c.units[0].endMs, 6033);
      expect(c.units[1].startMs, 6033);
    });

    test('选中单元，startEdge=true，-1 帧：边界后退一帧', () {
      final c = buildController();
      c.select(const EditorSelection.unit(1));

      final ok = c.nudgeSelectedEdge(startEdge: true, frames: -1);

      expect(ok, true);
      expect(c.units[0].endMs, 5967);
    });

    test('选中单元，startEdge=false：调整与后一单元的边界', () {
      final c = buildController();
      c.select(const EditorSelection.unit(0));

      final ok = c.nudgeSelectedEdge(startEdge: false, frames: 1);

      expect(ok, true);
      expect(c.units[0].endMs, 6033);
      expect(c.units[1].startMs, 6033);
    });

    test('首单元 startEdge=true 返回 false（无前一单元）', () {
      final c = buildController();
      c.select(const EditorSelection.unit(0));
      expect(c.nudgeSelectedEdge(startEdge: true, frames: 1), false);
    });

    test('末单元 startEdge=false 返回 false（无后一单元）', () {
      final c = buildController();
      c.select(const EditorSelection.unit(1));
      expect(c.nudgeSelectedEdge(startEdge: false, frames: 1), false);
    });

    test('选中镜头同理在单元内部换算', () {
      final c = buildController();
      c.select(const EditorSelection.shot(0, 1));

      final ok = c.nudgeSelectedEdge(startEdge: true, frames: 1);

      expect(ok, true);
      expect(c.units[0].shots[0].endMs, 3033);
      expect(c.units[0].shots[1].startMs, 3033);
    });

    test('单元内首镜头 startEdge=true 返回 false', () {
      final c = buildController();
      c.select(const EditorSelection.shot(0, 0));
      expect(c.nudgeSelectedEdge(startEdge: true, frames: 1), false);
    });
  });

  test('updateTranscript 更新台词并可撤销', () {
    final c = buildController();
    final ok = c.updateTranscript(0, '新台词');

    expect(ok, true);
    expect(c.units[0].transcript, '新台词');

    c.undo();
    expect(c.units[0].transcript, '第一段台词。');
  });

  test('updateTranscript 索引越界返回 false', () {
    final c = buildController();
    expect(c.updateTranscript(5, '新台词'), false);
  });

  test('select 触发 notifyListeners', () {
    final c = buildController();
    var notifyCount = 0;
    c.addListener(() => notifyCount++);

    c.select(const EditorSelection.unit(0));

    expect(notifyCount, 1);
    expect(c.selection?.unitIndex, 0);
    expect(c.selection?.shotIndex, isNull);
  });

  group('selection 不变量（合并/拆分/撤销后不悬空）', () {
    test('回归：合并后紧跟 nudge 不再抛 RangeError（原崩溃复现路径）', () {
      final c = buildController(); // 2 单元
      c.select(const EditorSelection.unit(1));

      expect(c.mergeSelectedWithPrevious(), true); // units 变为 1 个
      expect(c.units.length, 1);

      // 合并后仅剩 1 个单元，selection 应已重映射到 unit(0)；
      // 对 unit(0) 而言没有"前一单元"，nudge 应安全返回 false，而不是抛异常
      expect(() => c.nudgeSelectedEdge(startEdge: true, frames: 1), returnsNormally);
      expect(c.nudgeSelectedEdge(startEdge: true, frames: 1), false);
    });

    test('合并后 selection 指向合并后的单元（3 单元夹具，排除巧合对齐）', () {
      final c = buildController3();
      c.select(const EditorSelection.unit(1)); // 合并 unit1 并入 unit0

      expect(c.mergeSelectedWithPrevious(), true);
      expect(c.units.length, 2);
      expect(c.selection?.unitIndex, 0);
      expect(c.selection?.shotIndex, isNull);

      // nudge 应作用在"合并后"的边界（原 unit0.endMs=4000 已变为 8000），
      // 而不是合并前的陈旧边界
      final ok = c.nudgeSelectedEdge(startEdge: false, frames: 1);
      expect(ok, true);
      expect(c.units[0].endMs, 8033);
      expect(c.units[1].startMs, 8033);
    });

    test('镜头层合并后 selection 指向合并后的镜头', () {
      final c = buildController();
      c.select(const EditorSelection.shot(0, 1));

      expect(c.mergeSelectedWithPrevious(), true);
      expect(c.selection?.unitIndex, 0);
      expect(c.selection?.shotIndex, 0);
    });

    test('单元拆分后 selection 仍指向拆分后的前半单元（索引不变）', () {
      final c = buildController();
      c.select(const EditorSelection.unit(0));

      expect(c.splitSelectedAt(3000), true);

      expect(c.selection?.unitIndex, 0);
      expect(c.selection?.shotIndex, isNull);
      expect(c.units[0].endMs, 3000); // 确实是前半单元
    });

    test('镜头拆分后 selection 仍指向拆分后的前半镜头（索引不变）', () {
      final c = buildController();
      c.select(const EditorSelection.shot(0, 0));

      expect(c.splitSelectedAt(1500), true);

      expect(c.selection?.unitIndex, 0);
      expect(c.selection?.shotIndex, 0);
      expect(c.units[0].shots[0].endMs, 1500);
    });

    test('撤销一次合并（units 变多）后 selection 不越界', () {
      final c = buildController3();
      c.select(const EditorSelection.unit(1));
      expect(c.mergeSelectedWithPrevious(), true); // 3 → 2 个单元

      c.undo(); // 撤销合并，units 变回 3 个

      expect(c.units.length, 3);
      expect(c.selection, isNotNull);
      expect(c.selection!.unitIndex, inInclusiveRange(0, 2));
    });

    test('撤销一次拆分（units 变少）后若 selection 越界则置为 null', () {
      final c = buildController(); // 2 单元
      c.select(const EditorSelection.unit(0));
      expect(c.splitSelectedAt(3000), true); // 2 → 3 个单元

      // 手动选中拆分产生的第三个单元（原 unit1，现 index 2）
      c.select(const EditorSelection.unit(2));

      c.undo(); // 撤销拆分，units 变回 2 个：index 2 越界

      expect(c.units.length, 2);
      expect(c.selection, isNull);
    });
  });
}
