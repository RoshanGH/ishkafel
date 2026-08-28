import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/line_evidence.dart';
import 'package:ishkafel/core/script/script_doc.dart';

/// 这一行**人能看到、听到的每一样东西**，Agent 都要拿得到。
///
/// 用户的原话：「你想让 Agent 完全还原一个优秀的人的操作，那你首先得让它
/// 拥有所有这个人能够拥有的信息。然后这个人去命令他干活的时候，他才能拿到
/// 充分的信息，跟人的目标去对齐。」
///
/// 典型场景：人说「第 3 行你找的这个分镜不对」。Agent 得能**看见**
/// 那一镜长什么样、参考镜长什么样，才谈得上跟人确认「你是嫌画面太暗、
/// 还是这个动作不对」——否则只能瞎猜着重搜。
void main() {
  LineShot shot(int id, {int trim = 0, double speed = 1.0}) => LineShot(
      materialId: id,
      name: 'm$id',
      durationMs: 9000,
      allocMs: 2000,
      trimStartMs: trim,
      speed: speed);

  test('每一镜都要指出**成片里真正会出现的那一帧**在哪一刻', () {
    // 取段起点 3000ms 的镜，成片里出现的是素材第 3 秒往后的画面，
    // 不是素材开头
    final at = evidenceFrameAtMs(shot(1, trim: 3000));
    expect(at, greaterThanOrEqualTo(3000));
    expect(at, lessThan(3000 + 2000));
  });

  test('没取段的镜从头附近取——但不取第 0 帧，开头常是黑的', () {
    expect(evidenceFrameAtMs(shot(1)), greaterThan(0));
  });

  test('倍速不改变素材里的时刻', () {
    expect(evidenceFrameAtMs(shot(1, trim: 1000, speed: 2.0)),
        evidenceFrameAtMs(shot(1, trim: 1000)));
  });

  test('取段起点已经贴着素材末尾时，别取到素材外面去', () {
    const tail =
        LineShot(materialId: 1, name: 'm', durationMs: 4000, allocMs: 2000, trimStartMs: 3900);
    expect(evidenceFrameAtMs(tail), lessThan(4000));
  });
}
