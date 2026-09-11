import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/subtitle/subtitle_overlay.dart';
import 'package:ishkafel/features/workbench/timeline/subtitle_segments.dart';

/// 字幕轨分段的像素与命中。数据规则在 core/subtitle/subtitle_edit.dart。
void main() {
  /// 这一镜 5 秒、在轨上占 100~600px（每秒 100px）
  List<SubtitleSegmentBox> boxes([List<SubtitleLine>? lines]) =>
      subtitleSegmentBoxes(
        lines: lines ??
            const [
              SubtitleLine(startMs: 0, endMs: 500, text: 'a'),
              SubtitleLine(startMs: 3000, endMs: 4200, text: 'b'),
            ],
        slotDurationMs: 5000,
        blockLeft: 100,
        blockRight: 600,
      );

  group('位置', () {
    test('相对这一镜的时间线性映射到块体上', () {
      final b = boxes();
      expect(b[0].left, 100);
      expect(b[0].right, 150);
      expect(b[1].left, 400);
      expect(b[1].right, 520);
    });

    test('块体宽为 0 或坑位长为 0 时不画——除不动，也没东西可看', () {
      expect(
          subtitleSegmentBoxes(
              lines: const [SubtitleLine(startMs: 0, endMs: 1, text: 'a')],
              slotDurationMs: 0,
              blockLeft: 0,
              blockRight: 10),
          isEmpty);
      expect(
          subtitleSegmentBoxes(
              lines: const [SubtitleLine(startMs: 0, endMs: 1, text: 'a')],
              slotDurationMs: 100,
              blockLeft: 10,
              blockRight: 10),
          isEmpty);
    });
  });

  group('够不够宽展开', () {
    test('都够宽才展开', () {
      expect(subtitleSegmentsFit(boxes()), isTrue);
    });

    test('**最窄的那一段**说了算——一段 3px 的碎片混在大块之间既抓不住也看不懂',
        () {
      final narrow = boxes(const [
        SubtitleLine(startMs: 0, endMs: 2000, text: '长的'),
        SubtitleLine(startMs: 2000, endMs: 2030, text: '碎的'),
      ]);
      expect(subtitleSegmentsFit(narrow), isFalse);
    });

    test('一段都没有时不展开（那一镜没有字幕）', () {
      expect(subtitleSegmentsFit(const []), isFalse);
    });
  });

  group('抓住的是哪一头', () {
    test('左边缘改起点、右边缘改终点、中间整段平移', () {
      final b = boxes();
      expect(subtitleGrabAt(dx: 402, boxes: b)?.grab, SubtitleGrab.start);
      expect(subtitleGrabAt(dx: 518, boxes: b)?.grab, SubtitleGrab.end);
      expect(subtitleGrabAt(dx: 460, boxes: b)?.grab, SubtitleGrab.move);
      expect(subtitleGrabAt(dx: 460, boxes: b)?.index, 1);
    });

    test('手柄往外也能抓一点——差几像素点不中会让人反复试', () {
      expect(subtitleGrabAt(dx: 96, boxes: boxes())?.grab, SubtitleGrab.start);
    });

    test('窄段上两个手柄重叠：按中点劈开，总比两个都点不中强', () {
      final b = boxes(const [
        SubtitleLine(startMs: 0, endMs: 80, text: 'a'),
      ]);
      expect(b[0].width, lessThanOrEqualTo(subtitleEdgeHitPx * 2));
      expect(subtitleGrabAt(dx: 101, boxes: b)?.grab, SubtitleGrab.start);
      expect(subtitleGrabAt(dx: 107, boxes: b)?.grab, SubtitleGrab.end);
    });

    test('空白处返回 null——那儿可以留空，不该误抓到邻段', () {
      expect(subtitleGrabAt(dx: 300, boxes: boxes()), isNull);
    });
  });

  test('拖多少像素等于多少毫秒；块体宽 0 时不位移', () {
    expect(
        subtitleDeltaMs(
            deltaPx: 50, slotDurationMs: 5000, blockLeft: 100, blockRight: 600),
        500);
    expect(
        subtitleDeltaMs(
            deltaPx: 50, slotDurationMs: 5000, blockLeft: 100, blockRight: 100),
        0);
  });
}
