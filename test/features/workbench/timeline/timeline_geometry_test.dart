// test/features/workbench/timeline/timeline_geometry_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_geometry.dart';

void main() {
  test('fit 让全片恰好铺满视口', () {
    final g = TimelineGeometry.fit(durationMs: 96000, viewportWidthPx: 960);
    expect(g.msPerPx, 100);
    expect(g.totalWidthPx, 960);
    expect(g.msToPx(0), 0);
    expect(g.msToPx(96000), 960);
  });

  test('ms↔px 互逆且 pxToMs 有界', () {
    const g = TimelineGeometry(durationMs: 10000, msPerPx: 10, scrollPx: 50);
    expect(g.msToPx(1500), 100);
    expect(g.pxToMs(100), 1500);
    expect(g.pxToMs(-999), 0);
    expect(g.pxToMs(99999), 10000);
  });

  test('zoomAt 保持锚点处的时间不动', () {
    final g = TimelineGeometry.fit(durationMs: 60000, viewportWidthPx: 600);
    final anchorMs = g.pxToMs(300);
    final zoomed = g.zoomAt(300, 2, viewportWidthPx: 600);
    expect(zoomed.pxToMs(300), closeTo(anchorMs, 1));
    expect(zoomed.msPerPx, g.msPerPx / 2);
  });

  test('scrolledBy 夹在合法滚动范围内', () {
    const g = TimelineGeometry(durationMs: 60000, msPerPx: 50); // 总宽 1200
    expect(g.scrolledBy(-100, viewportWidthPx: 600).scrollPx, 0);
    expect(g.scrolledBy(9999, viewportWidthPx: 600).scrollPx, 600);
  });

  test('缩放下限不小于 fit（不允许缩到比全片还小）由调用方 clamp——zoomAt 缩小时 scroll 归位不越界', () {
    final g = TimelineGeometry.fit(durationMs: 60000, viewportWidthPx: 600);
    final out = g.zoomAt(300, 0.5, viewportWidthPx: 600);
    expect(out.scrollPx, greaterThanOrEqualTo(0));
  });

  test('rulerStepMs 按缩放选整档位', () {
    const zoomedIn = TimelineGeometry(durationMs: 60000, msPerPx: 10); // 1s=100px
    expect(zoomedIn.rulerStepMs(), 1000);
    const zoomedOut = TimelineGeometry(durationMs: 600000, msPerPx: 200); // 1s=5px
    expect(zoomedOut.rulerStepMs(), 30000); // 30s=150px ≥80
  });

  _resizeRegressions();
}

void _resizeRegressions() {
  group('窗口尺寸变化时时间线跟着变（真机反馈）', () {
    test('适应窗口状态下变宽：重新铺满，不在右边留一片空白', () {
      const durationMs = 92300;
      final fitted =
          TimelineGeometry.fit(durationMs: durationMs, viewportWidthPx: 1455);

      final resized =
          fitted.resizedTo(oldViewportWidthPx: 1455, newViewportWidthPx: 2000);

      expect(resized.totalWidthPx, closeTo(2000, 0.5),
          reason: '之前只 clamp 了滚动、没重算 msPerPx，'
              '窗口拉宽后时间线还是原来那么长，右边空一大块');
      expect(resized.zoomLevel(viewportWidthPx: 2000), closeTo(1, 0.001));
    });

    test('适应窗口状态下变窄：同样跟着收，不产生横向滚动', () {
      const durationMs = 92300;
      final fitted =
          TimelineGeometry.fit(durationMs: durationMs, viewportWidthPx: 2000);

      final resized =
          fitted.resizedTo(oldViewportWidthPx: 2000, newViewportWidthPx: 1200);

      expect(resized.totalWidthPx, closeTo(1200, 0.5));
      expect(resized.scrollPx, 0);
    });

    test('用户已经放大过：保持缩放倍数，不把他的视野重置掉', () {
      const durationMs = 92300;
      final zoomed = TimelineGeometry.fit(
              durationMs: durationMs, viewportWidthPx: 1455)
          .zoomAt(700, 4, viewportWidthPx: 1455);
      final beforeMsPerPx = zoomed.msPerPx;

      final resized =
          zoomed.resizedTo(oldViewportWidthPx: 1455, newViewportWidthPx: 2000);

      expect(resized.msPerPx, beforeMsPerPx,
          reason: '正放大着看某一段，拉一下窗口就被拉回全片视野，'
              '等于把用户的工作状态清掉了');
    });

    test('放大状态下变窄：滚动位置被夹回合法范围，不露空白', () {
      const durationMs = 92300;
      final zoomed = TimelineGeometry.fit(
              durationMs: durationMs, viewportWidthPx: 2000)
          .zoomAt(1000, 4, viewportWidthPx: 2000);
      final scrolledToEnd =
          zoomed.scrolledBy(999999, viewportWidthPx: 2000);

      final resized = scrolledToEnd.resizedTo(
          oldViewportWidthPx: 2000, newViewportWidthPx: 800);

      expect(resized.scrollPx,
          lessThanOrEqualTo(resized.totalWidthPx - 800 + 0.5));
    });

    test('首次布局（旧宽度为 0）按适应窗口处理', () {
      final any = TimelineGeometry.fit(
          durationMs: 92300, viewportWidthPx: 100);

      final resized =
          any.resizedTo(oldViewportWidthPx: 0, newViewportWidthPx: 1455);

      expect(resized.totalWidthPx, closeTo(1455, 0.5));
    });

    test('新宽度非法时原样返回，不产生 Infinity/NaN', () {
      final fitted =
          TimelineGeometry.fit(durationMs: 92300, viewportWidthPx: 1455);

      expect(fitted.resizedTo(oldViewportWidthPx: 1455, newViewportWidthPx: 0),
          same(fitted));
    });
  });
}
