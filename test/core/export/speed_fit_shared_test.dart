import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/speed_fit.dart';

/// 画面和声音必须用**同一个**倍率。这个函数是唯一一份判定：
/// **从起点起剩下的整条，全部变速铺满坑位**（视觉镜头替换的方案）。
void main() {
  test('没给起点：整条按候选与坑位之比变速', () {
    expect(
        SpeedFit.effectiveFactor(
            candidateMs: 3000, slotMs: 2000, trimStartMs: null),
        closeTo(1.5, 1e-9));
  });

  test('给了起点：跳过开头那截，剩下的整条铺满——照旧变速', () {
    expect(
        SpeedFit.effectiveFactor(
            candidateMs: 9000, slotMs: 2000, trimStartMs: 3000),
        closeTo(3.0, 1e-9),
        reason: '从 3 秒起还剩 6 秒，6 秒铺满 2 秒的坑位就是 3 倍。'
            '这里曾经判成 1.0（「截过就不再变速」），'
            '于是画面被剪掉一大截——真机上看到的就是这个');
  });

  test('起点是 0 跟没给起点一样', () {
    expect(
        SpeedFit.effectiveFactor(
            candidateMs: 9000, slotMs: 2000, trimStartMs: 0),
        closeTo(4.5, 1e-9),
        reason: '写 0 和不写是同一件事，不能因为「给了起点」就当成截过');
  });

  test('起点越界（比素材还长）：不拿负数去算倍率', () {
    expect(
        SpeedFit.effectiveFactor(
            candidateMs: 4000, slotMs: 3000, trimStartMs: 5000),
        1.0);
  });

  test('探不到候选时长：不变速（宁可不动，也不拿一个猜的倍率去改速度）', () {
    expect(
        SpeedFit.effectiveFactor(
            candidateMs: null, slotMs: 2000, trimStartMs: null),
        1.0);
  });
}
