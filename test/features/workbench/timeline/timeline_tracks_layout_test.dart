import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_hit_tester.dart';

void main() {
  group('时间线轨道总高与窗口尺寸的关系', () {
    test('六条轨加标题条后的总高有明确出处，避免悄悄涨过可用高度', () {
      // 20 + 4+(14+44) + 4+(14+26) + 4+(14+22) + 4+(14+24) + 4+(14+52) + 4+(14+34)
      expect(TimelineTracks.totalHeight, 330);
    });

    test('总高必须盖住最后一条轨的底边——预留少一格就有一条轨画在画布外', () {
      // 2026-09-08 真机：加字幕轨时预留高度还按五条轨算（290），而 painter
      // 无条件画到 330，音频波形轨整条落在画布外。更糟的是外层
      // SingleChildScrollView 的子高度取 max(视口高, 预留高)，预留高比视口
      // 还矮时子高度就等于视口高度，**根本不产生滚动**，那条轨永远够不着。
      expect(TimelineTracks.totalHeight, TimelineTracks.waveBottom,
          reason: '总高就是最后一条轨的底边，没有第二个出处');
    });

    test('字幕轨常驻，不按内容显隐', () {
      // 一条片子一个镜头都没换素材时，这条轨上确实什么都没有。但让它跟着
      // 内容出现/消失，用户就会以为「这个功能我这儿没有」——真机上问过一次
      //「是新的任务才有字幕轨吗」。配乐轨也是空着常驻，标题条上写清楚
      //「只有换过素材的镜头才烧字幕」，比藏起来有效。
      expect(TimelineTracks.subsBottom, greaterThan(TimelineTracks.subsTop));
      expect(TimelineTracks.bgmLabelTop,
          greaterThanOrEqualTo(TimelineTracks.subsBottom),
          reason: '字幕轨在镜头轨和配乐轨中间，恒定占位');
    });

    test('最小窗口下放不满六条轨——所以时间线区必须能纵向滚', () {
      // 与 macos/Runner/MainFlutterWindow.swift 的 minSize 保持一致
      const windowHeight = 880.0;
      const topBar = 52.0; // WorkbenchTopBar.preferredSize
      const bottomBar = 60.0; // WorkbenchBottomBar 固定高
      const divider = 1.0;
      const toolbarHeight = 50.0; // 时间线工具条（含 Material Slider）实测量级

      final bodyHeight = windowHeight - topBar - bottomBar - divider;
      final timelineArea = bodyHeight * 4 / 9; // 三栏区 : 时间线区 = 5 : 4
      final drawable = timelineArea - toolbarHeight;

      expect(drawable, lessThan(TimelineTracks.totalHeight),
          reason: '这是有意的：抬窗口最小高度会让 1440×900 的笔记本装不下整个'
              '窗口。差的这几十像素靠滚动兜底');
      // 兜底成立的前提：画布高取 max(视口高, 总高)，总高更大时才滚得动
      expect(TimelineTracks.totalHeight - drawable, lessThan(60),
          reason: '要滚的距离得小到一眼能看出「下面还有」，否则等于藏了一条轨');
    });
  });
}
