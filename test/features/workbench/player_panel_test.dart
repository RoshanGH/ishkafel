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
