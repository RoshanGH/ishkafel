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

    /// 时间线区的高度不再是死比例，而是「六条轨 + 工具条要多少就给多少」，
    /// 上下用 35% / 55% 夹住（见 workbench_body.dart 的 LayoutBuilder）。
    ///
    /// 2026-09-09 设计走查真机：写死 5:4 时，**默认的 1440×900 窗口下第六条
    /// 轨（音频波形）整条落在可视区外**——人不滚动就永远看不到波形，
    /// 而波形正是定位切点的主要依据。
    const toolbarHeight = 40.0;
    const topBar = 52.0; // WorkbenchTopBar.preferredSize
    const bottomBar = 60.0; // WorkbenchBottomBar 固定高
    const divider = 1.0;

    double timelineHeightFor(double windowHeight) {
      final body = windowHeight - topBar - bottomBar - divider;
      final wanted = TimelineTracks.totalHeight + toolbarHeight;
      return wanted.clamp(body * 0.35, body * 0.55);
    }

    test('默认窗口（1440×900）下六条轨全部看得见，不用滚', () {
      final drawable = timelineHeightFor(900) - toolbarHeight;

      expect(drawable, greaterThanOrEqualTo(TimelineTracks.totalHeight),
          reason: '差一点点就是「最后一条轨永远看不到」——而人不会想到去滚它');
    });

    test('从最小窗口到大屏，六条轨都看得见——一条都不许藏起来', () {
      // 窗口最小 880 高（MainFlutterWindow.swift），那时 body 是 767，
      // 上限 55% 给得出 422 > 370，够。再往上只会更宽裕
      for (final windowHeight in [880.0, 900.0, 1080.0, 1440.0, 2000.0]) {
        final drawable = timelineHeightFor(windowHeight) - toolbarHeight;

        expect(drawable, greaterThanOrEqualTo(TimelineTracks.totalHeight),
            reason: '$windowHeight 高的窗口下最后一条轨还是要滚才看得到，'
                '而人不会想到去滚它');
      }
    });

    test('屏幕再高，时间线也不会退化成一条缝', () {
      final body = 2000 - topBar - bottomBar - divider;

      expect(timelineHeightFor(2000), greaterThanOrEqualTo(body * 0.35 - 0.5),
          reason: 'CLAUDE.md 要「时间线占比要充足（参考剪映约 40%）」');
    });

    test('屏幕再矮，预览也不会被时间线挤没', () {
      final body = 880 - topBar - bottomBar - divider;

      expect(timelineHeightFor(880), lessThanOrEqualTo(body * 0.55 + 0.5),
          reason: '这里毕竟是「看画面」的地方');
    });
  });
}
