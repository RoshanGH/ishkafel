import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/playback/playback_controller.dart';
import 'package:ishkafel/features/workbench/player_panel.dart';

const _fps = 30.0;
const _durationMs = 10000;

Widget _wrap(FakePlaybackController playback) => MaterialApp(
      home: Material(
        child: PlayerPanel(
          playback: playback,
          durationMs: _durationMs,
          fps: _fps,
        ),
      ),
    );

void main() {
  _tightTransport();
  testWidgets('无视频组件时渲染占位舞台与 transport 控件', (tester) async {
    final playback = FakePlaybackController();
    await tester.pumpWidget(_wrap(playback));
    await tester.pump();

    expect(find.byKey(const Key('player-toggle-play')), findsOneWidget);
    expect(find.byKey(const Key('player-step-back')), findsOneWidget);
    expect(find.byKey(const Key('player-step-forward')), findsOneWidget);
    expect(find.byKey(const Key('player-seek-start')), findsOneWidget);
    expect(find.byKey(const Key('player-seek-end')), findsOneWidget);
  });

  testWidgets('时间码随播放位置更新', (tester) async {
    final playback = FakePlaybackController();
    await tester.pumpWidget(_wrap(playback));
    await tester.pump();

    expect(find.textContaining('00:00.00'), findsOneWidget);

    await playback.seekMs(2000);
    await tester.pump();

    expect(find.textContaining('00:02.00'), findsOneWidget);
  });

  testWidgets('点击播放/暂停按钮驱动 playback.play/pause', (tester) async {
    final playback = FakePlaybackController();
    await tester.pumpWidget(_wrap(playback));
    await tester.pump();

    await tester.tap(find.byKey(const Key('player-toggle-play')));
    await tester.pump();
    expect(playback.calls, contains('play()'));

    await tester.tap(find.byKey(const Key('player-toggle-play')));
    await tester.pump();
    expect(playback.calls, contains('pause()'));
  });

  testWidgets('空格键切换播放/暂停', (tester) async {
    final playback = FakePlaybackController();
    await tester.pumpWidget(_wrap(playback));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(playback.calls, contains('play()'));

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(playback.calls, contains('pause()'));
  });

  testWidgets('左右方向键 ±1 帧调用 stepFrames', (tester) async {
    final playback = FakePlaybackController();
    await tester.pumpWidget(_wrap(playback));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(playback.calls, contains('stepFrames(1, $_fps)'));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(playback.calls, contains('stepFrames(-1, $_fps)'));
  });

  testWidgets('点击 −1帧/+1帧 按钮调用 stepFrames', (tester) async {
    final playback = FakePlaybackController();
    await tester.pumpWidget(_wrap(playback));
    await tester.pump();

    await tester.tap(find.byKey(const Key('player-step-forward')));
    await tester.pump();
    expect(playback.calls, contains('stepFrames(1, $_fps)'));

    await tester.tap(find.byKey(const Key('player-step-back')));
    await tester.pump();
    expect(playback.calls, contains('stepFrames(-1, $_fps)'));
  });

  group('播放状态同步（评审 Important 2：盲翻转）', () {
    testWidgets('快速连按两次播放按钮后，图标与真实 isPlaying 保持一致', (tester) async {
      final playback = FakePlaybackController();
      await tester.pumpWidget(_wrap(playback));
      await tester.pump();

      // 直接同步调用两次 onPressed（不经过 tester.tap()/await，也不在两次
      // 调用间 pump）：两次 _togglePlay() 的决策都发生在第一次 play() 的
      // await 完成之前（微任务尚未有机会执行）——若用 await tester.tap()
      // 顺序点两次，两次调用间的 await 会让微任务先跑完，退化为普通顺序
      // 切换，测不出这个竞态场景。
      //
      // 决策已改为读取 [PlaybackController.isPlaying]（评审 Minor E），
      // 而非本地镜像字段：第一次调用 play() 时，FakePlaybackController 会
      // 同步把自己的 isPlaying 置为 true（异步只体现在 Future 完成通知被
      // 推迟到微任务），因此第二次调用能读到"已经播放中"这一真实状态，
      // 正确判定为暂停——不再像"决策读本地字段"时那样，两次都因为本地
      // 镜像字段的 setState 更新被推迟而误判成同一个操作（都调用 play()）。
      final button =
          tester.widget<IconButton>(find.byKey(const Key('player-toggle-play')));
      button.onPressed!();
      button.onPressed!();
      // 两次 setState 均发生在 await 之后的微任务里；第一次 pump 只驱动
      // 微任务队列排空，第二次 pump 才让由此触发的 rebuild 真正落到树上
      await tester.pump();
      await tester.pump();

      expect(playback.calls, ['play()', 'pause()'],
          reason: '第一次判定为播放、第二次基于真实状态正确判定为暂停');
      expect(playback.isPlaying, isFalse,
          reason: '第二次点击应正确生效为暂停，而不是被第一次未完成的 await 悄悄吞掉');
      final icon = tester.widget<Icon>(find.descendant(
          of: find.byKey(const Key('player-toggle-play')),
          matching: find.byType(Icon)));
      expect(icon.icon, Icons.play_circle_fill,
          reason: '图标应与真实播放状态一致（暂停态）');
    });

    testWidgets('外部改变 isPlaying（如自动暂停）后图标经 playingStream 同步', (tester) async {
      final playback = FakePlaybackController();
      await tester.pumpWidget(_wrap(playback));
      await tester.pump();

      await tester.tap(find.byKey(const Key('player-toggle-play')));
      await tester.pump();
      var icon = tester.widget<Icon>(find.descendant(
          of: find.byKey(const Key('player-toggle-play')),
          matching: find.byType(Icon)));
      expect(icon.icon, Icons.pause_circle_filled);

      // 不经过面板按钮，外部直接暂停（模拟播放到片尾自动暂停）
      await playback.pause();
      await tester.pump();
      await tester.pump();

      icon = tester.widget<Icon>(find.descendant(
          of: find.byKey(const Key('player-toggle-play')),
          matching: find.byType(Icon)));
      expect(icon.icon, Icons.play_circle_fill,
          reason: '外部暂停后图标应同步变为播放态图标');
    });
  });

  testWidgets('点击首尾按钮调用 seekMs(0)/seekMs(durationMs)', (tester) async {
    final playback = FakePlaybackController();
    await tester.pumpWidget(_wrap(playback));
    await tester.pump();

    await tester.tap(find.byKey(const Key('player-seek-end')));
    await tester.pump();
    expect(playback.calls, contains('seekMs($_durationMs)'));

    await tester.tap(find.byKey(const Key('player-seek-start')));
    await tester.pump();
    expect(playback.calls, contains('seekMs(0)'));
  });
}

/// 窄栏下时间码不许被咬掉。
///
/// 2026-09-09 设计走查真机截图：挑素材时中栏被压到 280，控制条那行显示的是
/// 「00:00.00 / 01:1」——横向滚动把后半截推出了可视区，而没有任何东西告诉
/// 人还能滚。挤不下就该换行，不该静默裁掉。
void _tightTransport() {
  Widget wrapWidth(double width, FakePlaybackController playback) => MaterialApp(
        home: Material(
          child: Center(
            child: SizedBox(
              width: width,
              height: 600,
              child: PlayerPanel(
                playback: playback,
                durationMs: 70000,
                fps: _fps,
              ),
            ),
          ),
        ),
      );

  testWidgets('窄栏下时间码整串都在，不被裁掉', (tester) async {
    final playback = FakePlaybackController();
    await tester.pumpWidget(wrapWidth(280, playback));
    await tester.pump();

    final clock = find.textContaining('/');
    expect(clock, findsOneWidget);
    // 文字自己没被截断
    expect(tester.widget<Text>(clock).data, contains('01:10'));
    // 而且真的画得下：文字的右边缘没有超出面板
    final panel = tester.getRect(find.byType(PlayerPanel));
    final rect = tester.getRect(clock);
    expect(rect.right, lessThanOrEqualTo(panel.right + 0.5),
        reason: '时间码被推出了可视区，人看到的是一个咬掉一半的数字');
    expect(rect.left, greaterThanOrEqualTo(panel.left - 0.5));
  });

  testWidgets('宽栏下还是一行，不平白多占一行高度', (tester) async {
    final playback = FakePlaybackController();
    await tester.pumpWidget(wrapWidth(600, playback));
    await tester.pump();

    final clock = tester.getRect(find.textContaining('/'));
    final play = tester.getRect(find.byKey(const Key('player-toggle-play')));

    expect((clock.center.dy - play.center.dy).abs(), lessThan(4),
        reason: '宽度够的时候时间码该和按钮并排');
  });
}
