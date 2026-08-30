import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/app/theme/app_colors.dart';
import 'package:ishkafel/core/storage/agent_broadcast.dart';
import 'package:ishkafel/features/agent/agent_broadcast_bar.dart';

/// 三类播报要**一眼分得开**。分不开的话，人只会把它们当成一串流水账
/// 划过去——而那条「这素材烧着别家的字」恰恰是他该当场喊停的一条。
void main() {
  Future<void> pump(WidgetTester tester, AgentBroadcast b) =>
      tester.pumpWidget(MaterialApp(
        home: Stack(children: [
          AgentBroadcastBar(broadcast: b, holder: 'Agent'),
        ]),
      ));

  testWidgets('发现问题的那条要显眼，和进度分得开', (tester) async {
    await pump(
        tester,
        AgentBroadcast.empty
            .push('正在挑素材')
            .push('这条画面上烧着别家的字', kind: BroadcastKind.warning));
    final warn = tester.widget<Text>(find.text('这条画面上烧着别家的字'));
    final step = tester.widget<Text>(find.text('正在挑素材'));
    expect(warn.style!.color, isNot(step.style!.color));
    expect(warn.style!.color, AppColors.orange);
  });

  testWidgets('判断类也要能认出来，但不能和「出问题了」撞色', (tester) async {
    await pump(
        tester,
        AgentBroadcast.empty
            .push('标签太宽，改用画面描述再搜一轮',
                kind: BroadcastKind.judgement)
            .push('这条烧着别家的字', kind: BroadcastKind.warning));
    final judge = tester.widget<Text>(find.text('标签太宽，改用画面描述再搜一轮'));
    final warn = tester.widget<Text>(find.text('这条烧着别家的字'));
    expect(judge.style!.color, isNot(warn.style!.color));
    expect(judge.style!.color, isNot(AppColors.orange));
  });

  testWidgets('警告即使已经走过去了也还是显眼的——人回头要找得到', (tester) async {
    await pump(
        tester,
        AgentBroadcast.empty
            .push('这条烧着别家的字', kind: BroadcastKind.warning)
            .push('接着挑下一条'));
    expect(tester.widget<Text>(find.text('这条烧着别家的字')).style!.color,
        AppColors.orange);
  });

  testWidgets('绝大多数是进度，样式保持原样不打扰', (tester) async {
    await pump(tester, AgentBroadcast.empty.push('正在给 U2S4 挑素材'));
    expect(tester.widget<Text>(find.text('正在给 U2S4 挑素材')).style!.color,
        AppColors.textPrimary);
  });
}
