import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/subtitle/subtitle_overlay.dart';
import 'package:ishkafel/core/subtitle/subtitle_track.dart';

/// 自定义字幕轨：**只有被替换的视觉镜头才有**，手改过就整份存下来。
///
/// 起因（2026-09-08 真机）：S1 和 S2 都换了素材，ASR 判定「了」这个字的
/// 声音落在 S2 里，于是 S2 的字幕以一个孤零零的「了」开头。ASR 没错、
/// 切点也没错——是「哪里断句好看」这件事本来就没法用规则算对，那是编导的判断。
///
/// 所以给一条能手改的字幕轨：**字幕是字幕，台词是台词**，改字幕不动 transcript。
void main() {
  const slot = SubtitleSlot(unitIndex: 1, shotIndex: 2);

  group('没手改过就不存', () {
    test('空轨里查不到任何坑位——导出照现在的算法现算', () {
      expect(const SubtitleTrack.empty().linesOf(slot), isNull);
    });

    test('存量任务读回来还是空的', () {
      expect(SubtitleTrack.fromJson(null).isEmpty, isTrue);
      expect(SubtitleTrack.fromJson(const []).isEmpty, isTrue);
    });
  });

  group('手改过就整份存', () {
    test('存下来的就是这一坑位的全部字幕', () {
      final track = const SubtitleTrack.empty().withLines(slot, const [
        SubtitleLine(startMs: 0, endMs: 800, text: '李斯特菌'),
        SubtitleLine(startMs: 800, endMs: 1600, text: '沙门氏菌的游乐场'),
      ]);

      expect(track.linesOf(slot)!.length, 2);
      expect(track.linesOf(slot)!.first.text, '李斯特菌');
    });

    test('删光了也要记下来——「我删空了」和「没改过」是两回事', () {
      final track = const SubtitleTrack.empty().withLines(slot, const []);

      expect(track.linesOf(slot), isNotNull,
          reason: '返回 null 的话导出会以为没改过，又照 ASR 算一份贴回去，'
              '用户删掉的那段字又回来了');
      expect(track.linesOf(slot), isEmpty);
    });

    test('改别的坑位不影响这个', () {
      final track = const SubtitleTrack.empty()
          .withLines(slot, const [SubtitleLine(startMs: 0, endMs: 1, text: 'a')])
          .withLines(const SubtitleSlot(unitIndex: 0, shotIndex: 0),
              const [SubtitleLine(startMs: 0, endMs: 1, text: 'b')]);

      expect(track.linesOf(slot)!.single.text, 'a');
    });

    test('改回自动：把这个坑位清掉，导出重新按 ASR 算', () {
      final track = const SubtitleTrack.empty()
          .withLines(slot, const [SubtitleLine(startMs: 0, endMs: 1, text: 'a')])
          .cleared(slot);

      expect(track.linesOf(slot), isNull);
    });
  });

  group('哪些坑位被手改过', () {
    test('列出来——界面要标记，切分变了也要照着它问', () {
      final track = const SubtitleTrack.empty()
          .withLines(slot, const [])
          .withLines(const SubtitleSlot(unitIndex: 0, shotIndex: 0), const []);

      expect(track.editedSlots.length, 2);
      expect(track.editedSlots, contains(slot));
    });
  });

  group('存档往返', () {
    test('写出去再读回来一模一样', () {
      final track = const SubtitleTrack.empty().withLines(slot, const [
        SubtitleLine(startMs: 120, endMs: 900, text: '李斯特菌'),
      ]);

      final back = SubtitleTrack.fromJson(track.toJson());

      expect(back.linesOf(slot)!.single.startMs, 120);
      expect(back.linesOf(slot)!.single.text, '李斯特菌');
    });

    test('脏数据不许让整条任务读不出来', () {
      final back = SubtitleTrack.fromJson([
        {'unit': 'x'},
        {'unit': 1, 'shot': 2, 'lines': 'not a list'},
      ]);

      expect(back.isEmpty, isTrue);
    });
  });
}
