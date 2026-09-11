import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/subtitle/subtitle_edit.dart';
import 'package:ishkafel/core/subtitle/subtitle_overlay.dart';

/// 改字幕段的时间——**属性卡里输数字和时间线上拖，走的是同一套规则**。
/// 两边各写一份的话，拖出来能做到的和输出来能做到的迟早不一样。
///
/// 用户 2026-09-11 定的：不能重叠、可以挨着、中间可以留空、不许拖出这一镜。
List<SubtitleLine> _lines() => const [
      SubtitleLine(startMs: 0, endMs: 500, text: '看看啊'),
      SubtitleLine(startMs: 3000, endMs: 4200, text: '哇这也太猛了'),
    ];

const _slot = 5000;

void main() {
  group('改起点', () {
    test('正常改', () {
      final out = setSubtitleStart(_lines(), 1, 2000, slotDurationMs: _slot);
      expect(out[1].startMs, 2000);
      expect(out[1].endMs, 4200, reason: '只动起点，终点不该跟着走');
    });

    test('不许越过前一段的尾巴——两句字同时在画面上就是打架', () {
      final out = setSubtitleStart(_lines(), 1, 200, slotDurationMs: _slot);
      expect(out[1].startMs, 500, reason: '顶在前一段的结束处');
    });

    test('挨着是允许的，重叠不行', () {
      final out = setSubtitleStart(_lines(), 1, 500, slotDurationMs: _slot);
      expect(out[1].startMs, 500);
    });

    test('第一段的下界是这一镜的开头，不是负数', () {
      final out = setSubtitleStart(_lines(), 0, -800, slotDurationMs: _slot);
      expect(out[0].startMs, 0);
    });

    test('不许把自己压成 0 长——至少留得住一眼', () {
      final out = setSubtitleStart(_lines(), 1, 4200, slotDurationMs: _slot);
      expect(out[1].startMs, 4200 - minSubtitleMs);
    });
  });

  group('改终点', () {
    test('不许越过后一段的头', () {
      final out = setSubtitleEnd(_lines(), 0, 3500, slotDurationMs: _slot);
      expect(out[0].endMs, 3000);
    });

    test('最后一段的上界是这一镜的长度——不许拖出这一镜', () {
      final out = setSubtitleEnd(_lines(), 1, 9999, slotDurationMs: _slot);
      expect(out[1].endMs, _slot);
    });

    test('不许压成 0 长', () {
      final out = setSubtitleEnd(_lines(), 0, 0, slotDurationMs: _slot);
      expect(out[0].endMs, minSubtitleMs);
    });
  });

  group('整体平移', () {
    test('长度一分不变', () {
      final out = moveSubtitle(_lines(), 1, 500, slotDurationMs: _slot);
      expect(out[1].startMs, 3500);
      expect(out[1].endMs, 4700);
    });

    test('往右顶到这一镜的末尾就停住，长度还是不变', () {
      final out = moveSubtitle(_lines(), 1, 5000, slotDurationMs: _slot);
      expect(out[1].endMs, _slot);
      expect(out[1].endMs - out[1].startMs, 1200);
    });

    test('往左顶到前一段的尾巴就停住', () {
      final out = moveSubtitle(_lines(), 1, -9999, slotDurationMs: _slot);
      expect(out[1].startMs, 500);
      expect(out[1].endMs, 1700);
    });

    test('中间留空是允许的——不像视频轨那样必须首尾相接', () {
      final out = moveSubtitle(_lines(), 1, -1000, slotDurationMs: _slot);
      expect(out[1].startMs, 2000);
      expect(out[0].endMs, 500, reason: '前一段不该被拽着走');
    });
  });

  group('不合理的输入不要把数据搞坏', () {
    test('下标越界原样返回', () {
      expect(setSubtitleStart(_lines(), 9, 100, slotDurationMs: _slot),
          _lines());
      expect(moveSubtitle(_lines(), -1, 100, slotDurationMs: _slot), _lines());
    });

    test('坑位比一段的最短长度还短：不动它，也不抛', () {
      expect(setSubtitleEnd(_lines(), 0, 300, slotDurationMs: 50), _lines());
    });

    test('镜头缩短之后，改一段会把它夹回新的范围内', () {
      final out = setSubtitleEnd(_lines(), 1, 4000, slotDurationMs: 3800);
      expect(out[1].endMs, lessThanOrEqualTo(3800));
    });
  });
}
