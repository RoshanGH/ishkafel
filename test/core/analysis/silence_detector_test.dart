import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/silence_detector.dart';

/// 生成 [durationMs] 毫秒、幅值 [amp] 的方波采样（16kHz）
List<int> tone(int durationMs, int amp) =>
    List.generate(16 * durationMs, (i) => i.isEven ? amp : -amp);

void main() {
  const detector = SilenceDetector();

  test('语音-静音-语音 检出一个居中的静音谷', () {
    final samples = [...tone(1000, 10000), ...tone(300, 0), ...tone(1000, 10000)];
    final centers = detector.detectValleyCenters(samples, 16000);
    expect(centers.length, 1);
    expect(centers.single, closeTo(1150, 40));
  });

  test('全程响亮无静音谷', () {
    expect(detector.detectValleyCenters(tone(2000, 10000), 16000), isEmpty);
  });

  test('短于 minSilenceMs 的停顿不算谷', () {
    final samples = [...tone(1000, 10000), ...tone(100, 0), ...tone(1000, 10000)];
    expect(detector.detectValleyCenters(samples, 16000), isEmpty);
  });

  test('空输入返回空', () {
    expect(detector.detectValleyCenters(const [], 16000), isEmpty);
  });
}
