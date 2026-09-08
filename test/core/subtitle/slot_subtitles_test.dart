import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/providers.dart' show AsrSentence;
import 'package:ishkafel/core/subtitle/slot_subtitles.dart';
import 'package:ishkafel/core/subtitle/subtitle_overlay.dart';
import 'package:ishkafel/core/subtitle/subtitle_track.dart';

/// **一个坑位要烧哪几行字，只能有一处说了算。**
///
/// 2026-09-08 真机：用户改完字幕，预览没变、导出烧的还是旧的。原因是同一件事
/// 有三处各算各的——属性面板读了手改轨，预览的变速切片和导出各自直接按 ASR
/// 现算，谁也不认那条轨。改一处修不好，改三处下次还会漏第四处。
void main() {
  final sentences = [
    AsrSentence(startMs: 0, endMs: 2000, text: '就变成了游乐场', words: const []),
  ];

  List<SubtitleLine> resolve(SubtitleTrack track) => subtitleLinesForSlot(
        track: track,
        sentences: sentences,
        unitIndex: 3,
        shotIndex: 1,
        slotStartMs: 0,
        slotEndMs: 2000,
      );

  test('没手改过：照 ASR 现算', () {
    expect(resolve(const SubtitleTrack.empty()).first.text, contains('游乐场'));
  });

  test('手改过：用手改的那份', () {
    final track = const SubtitleTrack.empty().withLines(
        const SubtitleSlot(unitIndex: 3, shotIndex: 1),
        const [SubtitleLine(startMs: 0, endMs: 900, text: '游乐场')]);

    expect(resolve(track).single.text, '游乐场');
  });

  test('手改成空：这一镜就是不要字幕，不许回退到自动算', () {
    final track = const SubtitleTrack.empty()
        .withLines(const SubtitleSlot(unitIndex: 3, shotIndex: 1), const []);

    expect(resolve(track), isEmpty);
  });

  test('改的是别的坑位，这一镜照旧自动算', () {
    final track = const SubtitleTrack.empty().withLines(
        const SubtitleSlot(unitIndex: 0, shotIndex: 0),
        const [SubtitleLine(startMs: 0, endMs: 1, text: '别人的')]);

    expect(resolve(track).first.text, contains('游乐场'));
  });

  group('指纹：改了字就必须重渲，不能命中旧切片', () {
    test('文字变了指纹就变', () {
      const a = [SubtitleLine(startMs: 0, endMs: 900, text: '游乐场')];
      const b = [SubtitleLine(startMs: 0, endMs: 900, text: '游乐场 你好')];

      expect(subtitleFingerprint(a), isNot(subtitleFingerprint(b)),
          reason: '指纹不变的话，预览会拿旧切片顶上——人看到的就是「改了没反应」');
    });

    test('时间变了指纹也变', () {
      const a = [SubtitleLine(startMs: 0, endMs: 900, text: '游乐场')];
      const b = [SubtitleLine(startMs: 0, endMs: 1500, text: '游乐场')];

      expect(subtitleFingerprint(a), isNot(subtitleFingerprint(b)));
    });

    test('一模一样就该命中，不白跑一遍 ffmpeg', () {
      const a = [SubtitleLine(startMs: 0, endMs: 900, text: '游乐场')];
      const b = [SubtitleLine(startMs: 0, endMs: 900, text: '游乐场')];

      expect(subtitleFingerprint(a), subtitleFingerprint(b));
    });

    test('没有字幕时是空指纹，不参与拼 key', () {
      expect(subtitleFingerprint(const []), isEmpty);
    });
  });
}
