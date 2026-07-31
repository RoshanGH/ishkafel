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
          transcript: '第一句台词',
          shots: [Shot(startMs: 0, endMs: 4000)],
        ),
        SemanticUnit(
          index: 1,
          startMs: 4000,
          endMs: 8000,
          transcript: '第二句台词',
          shots: [Shot(startMs: 4000, endMs: 8000)],
        ),
      ],
      durationMs: 8000,
      fps: 30,
      sentences: const [],
    );

void main() {
  group('编辑器不把内部状态交出去（改坏了不会有任何提示）', () {
    test('units 返回只读视图，外部无法就地增删', () {
      final controller = _controller();
      // 必须先做一次编辑：初始列表若由调用方传入 const 字面量，天生就是只读的，
      // 直接断言会得到一条假绿。编辑之后 _units 换成编辑操作新建的可增长列表，
      // 这才是真实场景。
      controller.select(const EditorSelection.unit(0));
      controller.nudgeSelectedEdge(startEdge: false, frames: -1);
      final units = controller.units;

      expect(() => units.removeAt(0), throwsUnsupportedError,
          reason: '外部拿到内部列表后就地删元素，会绕过 undo 栈与不变量校验，'
              '且没有任何提示——切分结构被悄悄改坏');
      expect(() => units.add(units.first), throwsUnsupportedError);
      expect(controller.units, hasLength(2), reason: '内部状态不受影响');
    });

    test('只读视图仍然如实反映后续编辑', () {
      final controller = _controller();
      expect(controller.units, hasLength(2));

      controller.select(const EditorSelection.unit(1));
      controller.mergeSelectedWithPrevious();

      expect(controller.units, hasLength(1),
          reason: '缓存只读视图时若忘了在状态变更后刷新，读到的就是旧数据');
    });
  });
}
