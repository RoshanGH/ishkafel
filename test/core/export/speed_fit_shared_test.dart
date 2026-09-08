import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/speed_fit.dart';

/// 画面和声音必须用**同一个**倍率。这个函数是唯一一份判定：
/// 截过一段等长的就不再变速（截完还变速等于白截）。
void main() {
  test('没截过：按候选与坑位之比变速', () {
    expect(
        SpeedFit.effectiveFactor(
            candidateMs: 3000, slotMs: 2000, trimStartMs: null),
        closeTo(1.5, 1e-9));
  });

  test('截过且截出来够长：不变速', () {
    expect(
        SpeedFit.effectiveFactor(
            candidateMs: 9000, slotMs: 2000, trimStartMs: 3000),
        1.0,
        reason: '从 3 秒起还剩 6 秒，够铺满 2 秒的坑位，截完再变速等于白截');
  });

  test('截过但剩下的不够长：还得变速', () {
    expect(
        SpeedFit.effectiveFactor(
            candidateMs: 4000, slotMs: 3000, trimStartMs: 2500),
        isNot(1.0));
  });

  test('探不到候选时长：不变速（宁可不动，也不拿一个猜的倍率去改速度）', () {
    expect(
        SpeedFit.effectiveFactor(
            candidateMs: null, slotMs: 2000, trimStartMs: null),
        1.0);
  });
}
