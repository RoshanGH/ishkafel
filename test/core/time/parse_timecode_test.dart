import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/time/timecode.dart';

/// 时间码要能**输回去**：屏幕上显示 `00:17.10`，人就会照着这个格式敲。
///
/// 2026-09-11 用户改了主意：字幕的时间用完整的时序帧，不用相对秒数
/// （「问了下同事还是这个更符合使用习惯」）。
void main() {
  test('照着显示的样子输：分:秒.帧', () {
    expect(parseTimecode('00:17.10', 30), 17 * 1000 + (10 * 1000 ~/ 30));
    expect(parseTimecode('01:02.00', 30), 62000);
  });

  test('帧位换算按帧率来——同样的 .15 在 30fps 和 60fps 不是一回事', () {
    expect(parseTimecode('00:01.15', 30), 1000 + 500);
    expect(parseTimecode('00:01.15', 60), 1000 + 250);
  });

  test('省掉分钟也认——人常常只敲秒', () {
    expect(parseTimecode('17.10', 30), 17 * 1000 + 333);
    expect(parseTimecode('17', 30), 17000);
  });

  test('帧号超出这一秒的范围：按满帧夹住，不进位成下一秒', () {
    // 30fps 下没有第 30 帧（0~29）；夹到 29 而不是变成 18 秒整
    expect(parseTimecode('00:17.30', 30), 17000 + (29 * 1000 ~/ 30));
  });

  test('认不出来就返回 null——不许猜一个数出来', () {
    for (final bad in ['', '  ', '呃', '1:2:3.4', '--', 'abc']) {
      expect(parseTimecode(bad, 30), isNull, reason: '「$bad」不该被认成时间');
    }
  });

  test('前后空格、全角冒号都认——人从别处粘过来常带这些', () {
    expect(parseTimecode(' 00:17.10 ', 30), parseTimecode('00:17.10', 30));
    expect(parseTimecode('00：17.10', 30), parseTimecode('00:17.10', 30));
  });

  test('帧率不合法时不装懂', () {
    expect(parseTimecode('00:01.00', 0), isNull);
  });

  test('转出去再转回来，落在同一帧上', () {
    for (final ms in [0, 1, 999, 17333, 75302]) {
      final text = formatTimecode(ms, 30);
      final back = parseTimecode(text, 30)!;
      expect(formatTimecode(back, 30), text,
          reason: '$ms → $text → $back 又显示成 ${formatTimecode(back, 30)}');
    }
  });
}
