import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_geometry.dart';

const _viewport = 800.0;
const _durationMs = 300000;

TimelineGeometry _fit() => TimelineGeometry.fit(
    durationMs: _durationMs, viewportWidthPx: _viewport);

void main() {
  group('缩放上下限（无钳制时能缩到内容比视口还窄、放大到几万倍）', () {
    test('缩不到 fit 以下：整片始终至少铺满视口', () {
      var g = _fit();
      for (var i = 0; i < 10; i++) {
        g = g.zoomAt(_viewport / 2, 1 / 1.2, viewportWidthPx: _viewport);
      }

      expect(g.totalWidthPx, greaterThanOrEqualTo(_viewport - 0.5),
          reason: '缩到 fit 以下时，内容右侧会空出一大片；而波形轨用的 pxToMs 是'
              '带钳制的，那片空白会被画成一条等高实心带，看起来像「视频结束后'
              '还有声音」');
      expect(g.msPerPx, closeTo(_fit().msPerPx, 0.001));
    });

    test('放大有上限，不会一路缩到亚像素级别', () {
      var g = _fit();
      for (var i = 0; i < 60; i++) {
        g = g.zoomAt(_viewport / 2, 1.2, viewportWidthPx: _viewport);
      }

      final zoom = _fit().msPerPx / g.msPerPx;
      expect(zoom, lessThanOrEqualTo(TimelineGeometry.maxZoom + 0.001),
          reason: '滑块上限是 20×，滚轮路径不受钳制的话能到几万倍，'
              '此时一帧横跨整个视口，任何操作都失去意义');
    });

    test('钳制不影响正常范围内的缩放', () {
      final g = _fit().zoomAt(0, 4, viewportWidthPx: _viewport);
      expect(_fit().msPerPx / g.msPerPx, closeTo(4, 0.001));
    });
  });

  group('缩放倍数可从 geometry 反推（滑块必须与实际缩放同步）', () {
    test('fit 状态为 1×', () {
      expect(_fit().zoomLevel(viewportWidthPx: _viewport), closeTo(1, 0.001));
    });

    test('放大 8 倍后反推为 8×', () {
      final g = _fit().zoomAt(0, 8, viewportWidthPx: _viewport);
      expect(g.zoomLevel(viewportWidthPx: _viewport), closeTo(8, 0.001),
          reason: '滑块若维护自己的历史值而不从 geometry 反推，滚轮缩放后'
              '滑块仍停在 1×，再拖滑块就会以错误基准算 factor——'
              '用户往左拖想缩小，画面反而放大');
    });
  });
}
