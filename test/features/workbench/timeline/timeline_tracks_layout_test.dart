import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_hit_tester.dart';

void main() {
  group('时间线轨道总高与窗口尺寸的关系', () {
    test('五条轨加标题条后的总高有明确出处，避免悄悄涨过可用高度', () {
      // 20 + 4+(14+44) + 4+(14+26) + 4+(14+24) + 4+(14+52) + 4+(14+34)
      expect(TimelineTracks.totalHeight, 290);
    });

    test('最小窗口尺寸下时间线区仍放得下全部五条轨', () {
      // 与 macos/Runner/MainFlutterWindow.swift 的 minSize 保持一致。
      // 这里守的是**下限**：contentMinSize 保证窗口不会比它更矮，
      // 因此只要下限成立，任何合法窗口尺寸都放得下。
      const windowHeight = 880.0;
      const topBar = 52.0; // WorkbenchTopBar.preferredSize
      const bottomBar = 60.0; // WorkbenchBottomBar 固定高
      const divider = 1.0;
      const toolbarHeight = 50.0; // 时间线工具条（含 Material Slider）实测量级

      final bodyHeight = windowHeight - topBar - bottomBar - divider;
      // 三栏区 : 时间线区 = 5 : 4。
      //
      // 原来是 3:2（时间线 40%），加上 BGM 轨之后放不下：五条轨要 290px，
      // 而 40% 只给得出 280。抬窗口最小高度会让 1440×900 的笔记本装不下
      // 整个窗口，因此改成把比例调到 44%——CLAUDE.md 要的是「时间线占比
      // 要充足（参考剪映约 40%）」，44% 只多不少。
      final timelineArea = bodyHeight * 4 / 9;
      final drawable = timelineArea - toolbarHeight;

      expect(drawable, greaterThanOrEqualTo(TimelineTracks.totalHeight),
          reason: '放不下时最后一条（音频波形）整条落在可视区外，用户既看不到'
              '波形，也看不到本轮为它加的「生成中/生成失败」占位——'
              '要么调窗口最小尺寸，要么调轨道高度或分区比例');
    });
  });
}
