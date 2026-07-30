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
}
