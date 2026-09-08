import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/segmentation_edit_ops.dart';
import 'package:ishkafel/core/editing/segmentation_editor_controller.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/features/workbench/workbench_summary.dart';

/// **加一个单元之后，「原片时长」不许跟着变长。**
///
/// 2026-09-08 真机（我自己传视频回归时点出来的）：底部写
/// 「时长 75.3s（原片 85.3s）」——两个数对调了。原片是 75.3s，成片才是 85.3s。
///
/// 根因：加单元走的是 `replaceUnitsForBlankTask(next, next.last.endMs)`，
/// 它把控制器的 durationMs 改成了手加单元链上去的假末尾。而那个字段的语义
/// 是**原片时长**，摘要里「原片」这个标签就此开始撒谎。
///
/// 加一段进来，变长的是**成片**，原片一帧没多。
void main() {
  SegmentationEditorController controllerWith(int sourceMs) =>
      SegmentationEditorController(
        initialUnits: [
          SemanticUnit(
              index: 0, startMs: 0, endMs: sourceMs, transcript: '原片这一段'),
        ],
        durationMs: sourceMs,
        fps: 30,
        sentences: const [],
      );

  test('加完之后 durationMs 还是原片时长', () {
    final c = controllerWith(75302);
    final next = SegmentationEditOps.appendUnit(c.units, fps: 30);

    // 修好的调用方：有原片的任务传原来的时长，不传链上去的假末尾
    c.replaceUnitsForBlankTask(next, c.durationMs);

    expect(c.durationMs, 75302,
        reason: '传 next.last.endMs 的话会变成 85302——那是手加单元的占位末尾，'
            '原片里根本没有那一段');
    expect(c.units.length, 2);
  });

  test('摘要里两个数不许对调', () {
    final text = workbenchSummaryText(
      units: const [
        SemanticUnit(index: 0, startMs: 0, endMs: 75302, transcript: 'a'),
        SemanticUnit(
            index: 1,
            startMs: 75302,
            endMs: 85302,
            transcript: '',
            hasSource: false),
      ],
      durationMs: 75302, // 原片
      composedMs: 85302, // 成片
      dirty: false,
      hasTagGroups: true,
    );

    expect(text, contains('时长 85.3s（原片 75.3s）'),
        reason: '真机上出现过反过来的「时长 75.3s（原片 85.3s）」');
  });

  test('空白任务照旧：没有原片，总长就是排出来的那些分子', () {
    final c = SegmentationEditorController(
        initialUnits: const [],
        durationMs: 0,
        fps: 30,
        sentences: const []);

    c.replaceUnitsForBlankTask(const [
      SemanticUnit(
          index: 0, startMs: 0, endMs: 8000, transcript: '', hasSource: false),
    ], 8000);

    expect(c.durationMs, 8000);
  });
}
