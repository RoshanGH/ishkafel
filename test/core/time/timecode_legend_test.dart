import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/time/timecode.dart';

/// `00:17.28` 的 `.28` 是帧号不是小数——界面不写清楚，人一定读错。
/// 2026-09-11 用户：「这对我造成了很大的困扰，我不理解这个东西」
void main() {
  test('帧率写给人看：整数不拖小数尾巴', () {
    expect(fpsLabel(30), '30fps');
    expect(fpsLabel(29.97), '29.97fps');
    expect(fpsLabel(59.94), '59.94fps');
    expect(fpsLabel(0), '未知帧率');
  });

  test('说明里三样都要有：格式、帧率、一个能当场对照的例子', () {
    final legend = timecodeLegend(30);
    expect(legend, contains('分:秒.帧'));
    expect(legend, contains('30fps'));
    expect(legend, contains('第 28 帧'), reason: '光说「是帧」还不够，要给例子');
  });

  test('例子里的帧号必须落在这个帧率的合法范围内', () {
    for (final fps in [24.0, 25.0, 30.0, 50.0, 60.0, 29.97]) {
      final legend = timecodeLegend(fps);
      final match = RegExp(r'第 (\d+) 帧').firstMatch(legend)!;
      final ff = int.parse(match.group(1)!);
      expect(ff, lessThan(fps.round()),
          reason: '$fps 下不可能有第 $ff 帧，例子本身就是错的');
    }
  });

  test('读不出帧率时不编一个例子出来', () {
    expect(timecodeLegend(0), '时间码 分:秒.帧');
  });
}
