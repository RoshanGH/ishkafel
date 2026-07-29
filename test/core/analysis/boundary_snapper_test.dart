import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/boundary_snapper.dart';

void main() {
  const snapper = BoundarySnapper();

  test('snapToFrame 按 30fps 量化到帧', () {
    expect(snapper.snapToFrame(1000, 30), 1000);
    expect(snapper.snapToFrame(1005, 30), 1000);
    expect(snapper.snapToFrame(1020, 30), 1033);
  });

  test('窗口内优先吸附镜头边界，即使静音谷更近', () {
    final result = snapper.snap(5000,
        shotBoundaries: [5400], silenceValleys: [5100], fps: 30);
    expect(result, snapper.snapToFrame(5400, 30));
  });

  test('窗口内无镜头边界时吸附静音谷', () {
    final result = snapper.snap(5000,
        shotBoundaries: [9000], silenceValleys: [5200], fps: 30);
    expect(result, snapper.snapToFrame(5200, 30));
  });

  test('窗口内两者皆无则原位帧对齐', () {
    final result = snapper.snap(5005,
        shotBoundaries: [9000], silenceValleys: [1000], fps: 30);
    expect(result, snapper.snapToFrame(5005, 30));
  });

  test('多候选取最近者', () {
    final result = snapper.snap(5000,
        shotBoundaries: [4700, 5250, 5590], silenceValleys: const [], fps: 30);
    expect(result, snapper.snapToFrame(5250, 30));
  });
}
