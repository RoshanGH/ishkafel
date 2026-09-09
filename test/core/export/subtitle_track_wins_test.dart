import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/providers.dart' show AsrSentence;
import 'package:ishkafel/core/subtitle/subtitle_overlay.dart';
import 'package:ishkafel/core/subtitle/subtitle_track.dart';

/// **手改过的字幕，导出时必须盖过自动算的那份。**
///
/// 这条如果反了，用户改完导出一看还是原来那个孤零零的「了」，
/// 只会以为「改了没生效」——而这类错不进任何日志。
void main() {
  const slot = SubtitleSlot(unitUid: 'u0', shotIndex: 1);

  /// 导出那一侧的取法（与 export_runner 里那段同构）
  List<SubtitleLine> resolve({
    required SubtitleTrack track,
    required List<AsrSentence> sentences,
    required int slotStartMs,
    required int slotEndMs,
  }) =>
      track.linesOf(slot) ??
      subtitleLinesInSlot(
        sentences: sentences,
        slotStartMs: slotStartMs,
        slotEndMs: slotEndMs,
      );

  final sentences = [
    AsrSentence(startMs: 0, endMs: 2000, text: '就变成了游乐场', words: const []),
  ];

  test('没手改过：照 ASR 算', () {
    final lines = resolve(
        track: const SubtitleTrack.empty(),
        sentences: sentences,
        slotStartMs: 0,
        slotEndMs: 2000);

    expect(lines, isNotEmpty);
    expect(lines.first.text, contains('游乐场'));
  });

  test('手改过：用手改的，不再算', () {
    final track = const SubtitleTrack.empty().withLines(
        slot, const [SubtitleLine(startMs: 0, endMs: 900, text: '游乐场')]);

    final lines = resolve(
        track: track, sentences: sentences, slotStartMs: 0, slotEndMs: 2000);

    expect(lines.single.text, '游乐场',
        reason: '开头那个孤零零的「了」正是用户删掉的，不能又给他算回来');
  });

  test('手改成空：这一镜就是不要字幕，不许回退到自动算', () {
    final track = const SubtitleTrack.empty().withLines(slot, const []);

    final lines = resolve(
        track: track, sentences: sentences, slotStartMs: 0, slotEndMs: 2000);

    expect(lines, isEmpty,
        reason: '「删空了」和「没改过」必须分得开——分不开的话，'
            '用户删掉的整段字幕会原样贴回成片');
  });

  test('改回自动：清掉之后又照 ASR 算', () {
    final track = const SubtitleTrack.empty()
        .withLines(slot, const [SubtitleLine(startMs: 0, endMs: 1, text: 'x')])
        .cleared(slot);

    final lines = resolve(
        track: track, sentences: sentences, slotStartMs: 0, slotEndMs: 2000);

    expect(lines.first.text, contains('游乐场'));
  });

  test('改的是这一镜，别的镜头照旧自动算', () {
    final track = const SubtitleTrack.empty().withLines(
        const SubtitleSlot(unitUid: 'u9', shotIndex: 9),
        const [SubtitleLine(startMs: 0, endMs: 1, text: '别人的')]);

    final lines = resolve(
        track: track, sentences: sentences, slotStartMs: 0, slotEndMs: 2000);

    expect(lines.first.text, contains('游乐场'));
  });
}
