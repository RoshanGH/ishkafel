import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/material_audio.dart';
import 'package:ishkafel/core/audio/source_audio.dart';
import 'package:ishkafel/features/workbench/source_audio_card.dart';

/// 「原片这一镜的声音」这张卡。四档 + 一个「自动」态。
void main() {
  ({MaterialAudioMode? mode, double? volume})? changed;

  Future<void> pump(
    WidgetTester tester, {
    SourceAudioSetting taskDefault = SourceAudioSetting.auto,
    MaterialAudioMode? shotMode,
    double? shotVolume,
    bool replaced = true,
    bool voiceSwapped = false,
    List<String> unreplacedSiblings = const [],
    bool hasVocals = true,
    bool hasBackground = true,
  }) async {
    changed = null;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SourceAudioCard(
            taskDefault: taskDefault,
            shotMode: shotMode,
            shotVolume: shotVolume,
            replaced: replaced,
            voiceSwapped: voiceSwapped,
            unreplacedSiblings: unreplacedSiblings,
            hasVocals: hasVocals,
            hasBackground: hasBackground,
            onChanged: (mode, volume) => changed = (mode: mode, volume: volume),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('没换素材的镜头：整张卡不出现', (tester) async {
    await pump(tester, replaced: false);
    expect(find.textContaining('原片这一镜的声音'), findsNothing,
        reason: '用户原话：没替换分镜就连这个操作都不该有');
  });

  testWidgets('没设过：四档都不选中，并写明「自动」在做什么', (tester) async {
    await pump(tester);

    expect(find.byKey(const Key('source-audio-auto')), findsOneWidget);
    for (final m in MaterialAudioMode.values) {
      final chip = tester.widget<ChoiceChip>(
          find.byKey(ValueKey('source-audio-${m.name}')));
      expect(chip.selected, isFalse,
          reason: '自动不是第五个档位，也不该冒充某一档');
    }
  });

  testWidgets('点一档就按那一档来，不再是自动', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('source-audio-vocals')));
    expect(changed?.mode, MaterialAudioMode.vocals);
  });

  testWidgets('全片设过、镜头没设：显示为跟随全片', (tester) async {
    await pump(tester,
        taskDefault:
            const SourceAudioSetting(mode: MaterialAudioMode.background));

    expect(find.text('跟随全片'), findsOneWidget);
    final chip = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('source-audio-background')));
    expect(chip.selected, isTrue);
  });

  testWidgets('换过音色的单元：说清原因，不摆一排点了没用的档位', (tester) async {
    await pump(tester, voiceSwapped: true);

    expect(find.byKey(const Key('source-audio-voice-swapped')), findsOneWidget);
    expect(find.byKey(const ValueKey('source-audio-vocals')), findsNothing);
  });

  testWidgets('这一句里有镜头没换素材：点名说会在句中突变', (tester) async {
    await pump(tester,
        shotMode: MaterialAudioMode.vocals, unreplacedSiblings: ['S2', 'S3']);

    final text = tester
        .widget<Text>(find.byKey(const Key('source-audio-midsentence')))
        .data!;
    expect(text, contains('S2、S3'));
  });

  testWidgets('选了原声就不提句中突变——没剥掉任何东西，接得上', (tester) async {
    await pump(tester,
        shotMode: MaterialAudioMode.original, unreplacedSiblings: ['S2']);
    expect(find.byKey(const Key('source-audio-midsentence')), findsNothing);
  });

  testWidgets('选了要分离的档位但没有那条轨：当场说清怎么补', (tester) async {
    await pump(tester,
        shotMode: MaterialAudioMode.background, hasBackground: false);

    expect(find.byKey(const Key('source-audio-stem-missing')), findsOneWidget);
  });

  testWidgets('压过音量就说清预览不带音量——别让人以为拖了没反应', (tester) async {
    await pump(tester,
        shotMode: MaterialAudioMode.original, shotVolume: 0.4);
    expect(find.byKey(const Key('source-audio-volume-preview-note')),
        findsOneWidget);

    await pump(tester, shotMode: MaterialAudioMode.original, shotVolume: 1.0);
    expect(find.byKey(const Key('source-audio-volume-preview-note')),
        findsNothing);
  });

  testWidgets('改回跟随全片：单独设过才给这条路', (tester) async {
    await pump(tester,
        taskDefault: const SourceAudioSetting(mode: MaterialAudioMode.vocals),
        shotMode: MaterialAudioMode.none);

    await tester.tap(find.byKey(const ValueKey('source-audio-unfollow')));
    expect(changed, isNotNull);
    expect(changed?.mode, isNull);
  });
}
