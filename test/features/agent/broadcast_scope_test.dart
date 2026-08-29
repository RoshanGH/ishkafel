import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/agent/broadcast_scope.dart';

/// 播报条只说「Agent 正在操作」，不说**在哪个任务上**。
///
/// 验收 Agent 撞到：它自己没跑任何命令，界面却在动、播报在滚——
/// 另一个会话正在操作别的任务。它一度以为是「界面跟错任务」，差点报成 bug。
///
/// 人更分不清：屏幕上写着「Agent 正在操作」，而人正看着 #9，
/// 动的其实是 #11。
void main() {
  test('干哪条任务就报哪条', () {
    expect(broadcastScopeLabel(actingTaskSeq: 11), '#11');
  });

  test('不属于任何任务的活儿（比如新建任务）不用报任务号', () {
    expect(broadcastScopeLabel(actingTaskSeq: null), isNull);
  });
}
