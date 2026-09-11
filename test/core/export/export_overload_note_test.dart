import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/export_runner.dart';

/// 过载这件事要**一路带到人眼前**。
///
/// 项目里踩过的教训：存了却不报，查到的空看起来正好像「没问题」。合成那一层
/// 量出了过载、却停在 [AudioTrack.overloads] 里没人读，等于没量
/// （2026-09-11 复盘）。
///
/// 它和「失败」是两回事：片子是导得出来的，只是某一段听着会发破——
/// 调不调是人的判断，所以走的是**成功的那条路上的一行备注**，不是 failure。
void main() {
  group('导出结果要带得动「这一条有一段过载」', () {
    test('成功的那一条也能带备注', () {
      const outcome = ExportOutcome(
        index: 1,
        path: '/out/变体1.mp4',
        notes: ['U1·S2 的镜头声音叠上去之后这一段过载了'],
      );

      expect(outcome.ok, isTrue, reason: '过载不是失败');
      expect(outcome.notes, hasLength(1));
    });

    test('不带备注时是空的，不是 null——调用方不该到处判空', () {
      const outcome = ExportOutcome(index: 1, path: '/out/变体1.mp4');

      expect(outcome.notes, isEmpty);
    });
  });
}
