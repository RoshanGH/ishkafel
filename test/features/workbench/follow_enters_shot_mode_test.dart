import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/workbench/agent_focus_request.dart';
import 'package:ishkafel/features/workbench/follow_mode.dart';

/// 播报说「正在给 U2S3 挑素材」，右栏却写着「U2 保留原片 / 要替换的话，
/// 先在上方选择整体替换或镜头替换」——**两句话打架**。
///
/// 验收 Agent 的原话：「这个场景恰恰是最常见的：任何一条新任务，
/// 第一次挑素材时必然处在『还没设替换模式』的状态。人第一次看你干活，
/// 看到的就是这个。」
///
/// 人自己要给某一镜挑素材时，第一步就是点「镜头替换」。跟随也该这么走。
void main() {
  test('Agent 要给某一镜挑素材：该先切到镜头替换', () {
    final want = shouldEnterShotMode(
      const AgentFocusRequest(
          step: 1, unitIndex: 1, shotIndex: 3, wantsCandidates: true),
      canUsePerShot: true,
      alreadyPerShot: false,
    );

    expect(want, isTrue);
  });

  test('已经是镜头替换了就别再切——切一次会清空这个单元已选的东西', () {
    expect(
        shouldEnterShotMode(
          const AgentFocusRequest(
              step: 1, unitIndex: 1, shotIndex: 3, wantsCandidates: true),
          canUsePerShot: true,
          alreadyPerShot: true,
        ),
        isFalse);
  });

  test('这个单元切不出镜头时不硬切', () {
    expect(
        shouldEnterShotMode(
          const AgentFocusRequest(
              step: 1, unitIndex: 1, shotIndex: 3, wantsCandidates: true),
          canUsePerShot: false,
          alreadyPerShot: false,
        ),
        isFalse);
  });

  test('只是看看（不挑素材）就别动模式——那是替人做决定', () {
    expect(
        shouldEnterShotMode(
          const AgentFocusRequest(step: 1, unitIndex: 1, shotIndex: 3),
          canUsePerShot: true,
          alreadyPerShot: false,
        ),
        isFalse);
  });

  test('挑的是整个单元的素材（没指镜头），也别动模式', () {
    expect(
        shouldEnterShotMode(
          const AgentFocusRequest(step: 1, unitIndex: 1, wantsCandidates: true),
          canUsePerShot: true,
          alreadyPerShot: false,
        ),
        isFalse);
  });
}
