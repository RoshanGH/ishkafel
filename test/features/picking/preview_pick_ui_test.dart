import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/features/picking/picking_controller.dart';

List<SemanticUnit> _units() => [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 4000,
        transcript: 'U1',
        shots: [
          Shot(startMs: 0, endMs: 2000),
          Shot(startMs: 2000, endMs: 4000),
        ],
      ),
    ];

PickingController _controller() =>
    PickingController(units: _units());

void main() {
  group('整体替换：指定预览版', () {
    test('第一个勾选的自动成为预览版', () {
      final c = _controller()..setMode(ReplacementMode.whole);

      c.toggleCandidate(71);
      c.toggleCandidate(72);

      expect(c.previewCandidateId, 71);
    });

    test('可以改到另一个', () {
      final c = _controller()..setMode(ReplacementMode.whole);
      c.toggleCandidate(71);
      c.toggleCandidate(72);

      c.setPreviewCandidate(72);

      expect(c.previewCandidateId, 72);
    });

    test('没勾选的候选设不了预览版——预览只能放选中的', () {
      final c = _controller()..setMode(ReplacementMode.whole);
      c.toggleCandidate(71);

      c.setPreviewCandidate(99);

      expect(c.previewCandidateId, 71);
    });

    test('取消勾选预览版那一条时，退回第一个还留着的', () {
      final c = _controller()..setMode(ReplacementMode.whole);
      c.toggleCandidate(71);
      c.toggleCandidate(72);
      c.setPreviewCandidate(72);

      c.toggleCandidate(72);

      expect(c.previewCandidateId, 71,
          reason: '预览指向一个已经取消的候选，播放时就不知道该放什么');
    });

    test('指定预览版不影响导出条数', () {
      final c = _controller()..setMode(ReplacementMode.whole);
      c.toggleCandidate(71);
      c.toggleCandidate(72);
      c.setPreviewCandidate(72);

      expect(c.currentReplacement.factor, 2);
    });
  });

  group('镜头替换：每个镜头各有各的预览版', () {
    test('切到别的镜头时预览版跟着切', () {
      final c = _controller()..setMode(ReplacementMode.perShot);
      c.selectShot(0);
      c.toggleCandidate(11);
      c.toggleCandidate(12);
      c.setPreviewCandidate(12);

      c.selectShot(1);
      c.toggleCandidate(21);

      expect(c.previewCandidateId, 21);

      c.selectShot(0);
      expect(c.previewCandidateId, 12, reason: 'S1 的预览版不该被 S2 覆盖');
    });
  });
}
