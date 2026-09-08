import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/material_audio.dart';
import 'package:ishkafel/features/workbench/material_audio_card.dart';

void main() {
  ({MaterialAudioMode? mode, double? volume})? changed;

  Future<void> pump(
    WidgetTester tester, {
    MaterialAudioSetting taskDefault = MaterialAudioSetting.off,
    MaterialAudioMode? shotMode,
    double? shotVolume,
    bool replaced = true,
    String? materialVoiceover,
  }) async {
    changed = null;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MaterialAudioCard(
          taskDefault: taskDefault,
          shotMode: shotMode,
          shotVolume: shotVolume,
          replaced: replaced,
          materialVoiceover: materialVoiceover,
          onChanged: (mode, volume) => changed = (mode: mode, volume: volume),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('没换素材的镜头：这一项根本不该出现', (tester) async {
    await pump(tester, replaced: false);

    expect(find.textContaining('替换分镜的声音'), findsNothing,
        reason: '没有替换素材就没有「素材的声音」可言，摆出来只会让人困惑');
  });

  testWidgets('没单独设过：跟着全片那一档显示为选中，并标出「跟随全片」',
      (tester) async {
    await pump(tester,
        taskDefault: const MaterialAudioSetting(
            mode: MaterialAudioMode.background, volume: 0.3));

    // 四档里「背景声」是当前生效的那个
    expect(
        tester
            .widget<ChoiceChip>(
                find.byKey(const ValueKey('material-audio-background')))
            .selected,
        isTrue);
    expect(find.text('跟随全片'), findsOneWidget,
        reason: '要让人看出这一档是跟来的，不是他自己设的');
  });

  testWidgets('不摆「跟随全片」这个平级选项——它和「不播放」看起来一模一样',
      (tester) async {
    // 全片默认就是「不播放」，这时两个按钮做的是同一件事，
    // 人第一次点开看到的就是两个重复项
    await pump(tester);

    expect(find.byKey(const ValueKey('material-audio-follow')), findsNothing);
  });

  testWidgets('四档之外不多摆按钮', (tester) async {
    await pump(tester);

    expect(find.byType(ChoiceChip), findsNWidgets(4));
  });

  testWidgets('单独设过之后才出现「改回跟随全片」', (tester) async {
    await pump(tester, shotMode: MaterialAudioMode.vocals);

    expect(find.byKey(const ValueKey('material-audio-unfollow')),
        findsOneWidget);
  });

  testWidgets('没单独设过时不摆「改回跟随」——本来就跟着，点了没意义',
      (tester) async {
    await pump(tester);

    expect(find.byKey(const ValueKey('material-audio-unfollow')), findsNothing);
  });

  testWidgets('点「改回跟随全片」：回调带 null，把覆盖清掉', (tester) async {
    await pump(tester, shotMode: MaterialAudioMode.vocals);

    await tester.tap(find.byKey(const ValueKey('material-audio-unfollow')));
    await tester.pumpAndSettle();

    expect(changed?.mode, isNull);
  });

  testWidgets('这一镜单独选一档：回调带上那一档', (tester) async {
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('material-audio-original')));
    await tester.pumpAndSettle();

    expect(changed?.mode, MaterialAudioMode.original);
  });

  testWidgets('这一镜单独选「不播放」：回调带 none，不是 null', (tester) async {
    await pump(tester,
        taskDefault: const MaterialAudioSetting(mode: MaterialAudioMode.original));

    await tester.tap(find.byKey(const ValueKey('material-audio-none')));
    await tester.pumpAndSettle();

    expect(changed?.mode, MaterialAudioMode.none,
        reason: 'null 是「跟随全片」，全片放原声时它等于放——那不是用户点「不播放」的意思');
  });

  testWidgets('素材自己带口播时提示，但不拦', (tester) async {
    await pump(tester,
        taskDefault: const MaterialAudioSetting(mode: MaterialAudioMode.original),
        materialVoiceover: '这款清洁剂真的很好用');

    expect(find.textContaining('自己带口播'), findsOneWidget);
    expect(find.byKey(const ValueKey('material-audio-original')), findsOneWidget,
        reason: '只提示不拦——有时候要的就是那句话');
  });

  testWidgets('素材没口播就不提示，别制造噪音', (tester) async {
    await pump(tester, taskDefault: const MaterialAudioSetting(mode: MaterialAudioMode.original));

    expect(find.textContaining('自己带口播'), findsNothing);
  });

  testWidgets('「不播放」时不摆音量条——调一个不响的东西没有意义', (tester) async {
    await pump(tester);

    expect(find.byType(Slider), findsNothing);
  });

  testWidgets('会出声的档位才有音量条', (tester) async {
    await pump(tester, shotMode: MaterialAudioMode.original);

    expect(find.byType(Slider), findsOneWidget);
  });
}
