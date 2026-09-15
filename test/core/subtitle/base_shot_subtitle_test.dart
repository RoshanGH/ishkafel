import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/providers.dart' show AsrSentence;
import 'package:ishkafel/core/subtitle/slot_subtitles.dart';
import 'package:ishkafel/core/subtitle/subtitle_overlay.dart';
import 'package:ishkafel/core/subtitle/subtitle_track.dart';

/// 底片是**挑来的素材**时，ASR 那份现算的字幕一个字都不能用：时间戳量的是
/// 原片，而画面已经换成另一条片子，取出来的台词跟画面毫不相干——它会被
/// 结结实实烧进成片。
///
/// 2026-09-15：「替换的台词语义单元里的视觉镜头换了之后，相关的操作对齐了
/// 吗？比如字幕，比如音轨。」查下来字幕这条正是没对齐的。
void main() {
  final sentences = [
    const AsrSentence(
        startMs: 11000, endMs: 13500, text: '这是原片这一段的台词', words: []),
  ];

  test('底片是原片：照 ASR 现算，老行为不变', () {
    final lines = subtitleLinesForSlot(
      track: const SubtitleTrack.empty(),
      sentences: sentences,
      unitUid: 'u2',
      shotIndex: 1,
      slotStartMs: 10000,
      slotEndMs: 14000,
    );

    expect(lines, isNotEmpty);
  });

  test('底片是素材：一行都不给——ASR 量的是原片，跟这段画面无关', () {
    final lines = subtitleLinesForSlot(
      track: const SubtitleTrack.empty(),
      sentences: sentences,
      unitUid: 'u2',
      shotIndex: 1,
      slotStartMs: 12000,
      slotEndMs: 14480,
      onMaterialBase: true,
    );

    expect(lines, isEmpty,
        reason: '拿原片台词烧到素材画面上，时间和内容都对不上');
  });

  test('人手排过的照样认——他知道自己在干什么', () {
    const slot = SubtitleSlot(unitUid: 'u2', shotIndex: 1);
    final track = const SubtitleTrack.empty().withLines(
        slot, const [SubtitleLine(startMs: 0, endMs: 1200, text: '我自己排的')]);

    final lines = subtitleLinesForSlot(
      track: track,
      sentences: sentences,
      unitUid: 'u2',
      shotIndex: 1,
      slotStartMs: 12000,
      slotEndMs: 14480,
      onMaterialBase: true,
    );

    expect(lines.single.text, '我自己排的');
  });

  test('手改成空（这一镜就是不要字幕）在底片上同样成立', () {
    const slot = SubtitleSlot(unitUid: 'u2', shotIndex: 1);
    final track =
        const SubtitleTrack.empty().withLines(slot, const <SubtitleLine>[]);

    expect(
      subtitleLinesForSlot(
        track: track,
        sentences: sentences,
        unitUid: 'u2',
        shotIndex: 1,
        slotStartMs: 12000,
        slotEndMs: 14480,
        onMaterialBase: true,
      ),
      isEmpty,
    );
  });
}
