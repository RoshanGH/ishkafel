import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/segmentation_editor_controller.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';

SegmentationEditorController _controller() => SegmentationEditorController(
      initialUnits: const [
        SemanticUnit(
          index: 0,
          startMs: 0,
          endMs: 4000,
          transcript: 'U1',
          shots: [Shot(startMs: 0, endMs: 2000), Shot(startMs: 2000, endMs: 4000)],
        ),
        SemanticUnit(
          index: 1,
          startMs: 4000,
          endMs: 8000,
          transcript: 'U2',
          shots: [Shot(startMs: 4000, endMs: 8000)],
        ),
        SemanticUnit(
          index: 2,
          startMs: 8000,
          endMs: 12000,
          transcript: 'U3',
          shots: [Shot(startMs: 8000, endMs: 12000)],
        ),
      ],
      durationMs: 12000,
      fps: 30,
      sentences: const [],
    );

void main() {
  group('选中对象的键盘导航（专业工具都能用方向键在对象间移动）', () {
    test('未选中时，向后移动选中第一个单元', () {
      final c = _controller();
      expect(c.selection, isNull);

      c.selectAdjacent(1);

      expect(c.selection?.unitIndex, 0);
      expect(c.selection?.shotIndex, isNull);
    });

    test('单元层：在单元之间前后移动', () {
      final c = _controller()..select(const EditorSelection.unit(1));

      c.selectAdjacent(1);
      expect(c.selection?.unitIndex, 2);

      c.selectAdjacent(-1);
      expect(c.selection?.unitIndex, 1);
    });

    test('到头/到尾时停住，不回绕', () {
      final c = _controller()..select(const EditorSelection.unit(0));

      c.selectAdjacent(-1);
      expect(c.selection?.unitIndex, 0,
          reason: '回绕到末尾会让用户失去位置感，专业工具都是停在边界');

      c.select(const EditorSelection.unit(2));
      c.selectAdjacent(1);
      expect(c.selection?.unitIndex, 2);
    });

    test('镜头层：跨单元连续移动，而不是卡在单元内', () {
      final c = _controller()..select(const EditorSelection.shot(0, 1));

      // U1 的最后一个镜头 → 下一个应是 U2 的第一个镜头
      c.selectAdjacent(1);
      expect(c.selection?.unitIndex, 1);
      expect(c.selection?.shotIndex, 0,
          reason: '视觉镜头是连续覆盖整片的，导航到单元末尾就卡住不符合直觉');

      // 反向回到 U1 的最后一个镜头
      c.selectAdjacent(-1);
      expect(c.selection?.unitIndex, 0);
      expect(c.selection?.shotIndex, 1);
    });

    test('导航到的对象起点可供上层用来同步播放头', () {
      final c = _controller()..select(const EditorSelection.unit(0));
      c.selectAdjacent(1);
      expect(c.selectedStartMs, 4000);

      c.select(const EditorSelection.shot(0, 1));
      expect(c.selectedStartMs, 2000);
    });
  });
}
