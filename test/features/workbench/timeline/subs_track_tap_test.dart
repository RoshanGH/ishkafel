import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_hit_tester.dart';

/// **点时间线上的字幕块，就选中那一镜。**
///
/// 2026-09-08 真机，用户原话：「能不能直接选中字幕直接改啊？」——轨上明明画着
/// 那几段字，点下去却什么也不发生；人得自己在视觉镜头轨上数出是第几镜、
/// 再去右边找编辑框。
void main() {
  group('字幕轨的纵向范围', () {
    test('落在字幕轨里', () {
      final y = (TimelineTracks.subsTop + TimelineTracks.subsBottom) / 2;

      expect(TimelineTracks.isOnSubsTrack(y), isTrue);
    });

    test('镜头轨、配乐轨都不算', () {
      expect(
          TimelineTracks.isOnSubsTrack(
              (TimelineTracks.shotsTop + TimelineTracks.shotsBottom) / 2),
          isFalse);
      expect(
          TimelineTracks.isOnSubsTrack(
              (TimelineTracks.bgmTop + TimelineTracks.bgmBottom) / 2),
          isFalse);
    });

    test('边界：上沿算、下沿不算——两条轨紧挨着，不能都命中', () {
      expect(TimelineTracks.isOnSubsTrack(TimelineTracks.subsTop), isTrue);
      expect(TimelineTracks.isOnSubsTrack(TimelineTracks.subsBottom), isFalse);
    });
  });
}
