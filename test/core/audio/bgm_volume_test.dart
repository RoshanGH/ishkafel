import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/export/export_commands.dart';

const _a = BgmMaterial(
    id: 1, name: '甲', durationMs: 30000, previewUrl: 'https://o/a.mp3');
const _b = BgmMaterial(
    id: 2, name: '乙', durationMs: 30000, previewUrl: 'https://o/b.mp3');

void main() {
  group('每一段配乐各有各的音量', () {
    test('不指定时用默认值——压到四分之一，别盖过口播', () {
      final plan = BgmPlan.empty.assign(
          startUnit: 0, endUnit: 2, materials: [_a], rangeMs: 5000);

      expect(plan.segments.single.volume, BgmSegment.defaultVolume);
      expect(BgmSegment.defaultVolume, 0.25);
    });

    test('两段各调各的，互不影响', () {
      final plan = BgmPlan.empty
          .assign(
              startUnit: 0,
              endUnit: 2,
              materials: [_a],
              rangeMs: 5000,
              volume: 0.4)
          .assign(
              startUnit: 5,
              endUnit: 7,
              materials: [_b],
              rangeMs: 5000,
              volume: 0.1);

      expect(plan.segments[0].volume, 0.4);
      expect(plan.segments[1].volume, 0.1,
          reason: '一个全局音量必然有一段不合适——有的曲子本来就响，有的很闷');
    });

    test('只改音量不换曲子', () {
      final plan = BgmPlan.empty.assign(
          startUnit: 0, endUnit: 2, materials: [_a], rangeMs: 5000);

      final louder = plan.withVolume(startUnit: 0, volume: 0.6);

      expect(louder.segments.single.volume, 0.6);
      expect(louder.segments.single.previewMaterial.id, 1, reason: '曲子不能被换掉');
      expect(plan.segments.single.volume, BgmSegment.defaultVolume,
          reason: '不能就地改——撤销就没得撤了');
    });

    test('改一个不存在的段落时原样返回，不炸', () {
      final plan = BgmPlan.empty.assign(
          startUnit: 0, endUnit: 2, materials: [_a], rangeMs: 5000);

      expect(plan.withVolume(startUnit: 99, volume: 0.6).segments.single.volume,
          BgmSegment.defaultVolume);
    });

    test('拖动段落边界时音量跟着走', () {
      final plan = BgmPlan.empty.assign(
          startUnit: 0,
          endUnit: 2,
          materials: [_a],
          rangeMs: 5000,
          volume: 0.4);

      expect(plan.segments.single.copyWith(endUnit: 4).volume, 0.4);
    });

    test('音量越界时夹回 0~1，不产生负音量或爆音', () {
      final plan = BgmPlan.empty.assign(
          startUnit: 0,
          endUnit: 2,
          materials: [_a],
          rangeMs: 5000,
          volume: 9.0);

      expect(plan.segments.single.volume, 1.0);
      expect(plan.withVolume(startUnit: 0, volume: -1).segments.single.volume,
          0.0);
    });
  });

  group('存得住', () {
    test('存了再读回来还是那个音量', () {
      final plan = BgmPlan.empty.assign(
          startUnit: 0,
          endUnit: 2,
          materials: [_a],
          rangeMs: 5000,
          volume: 0.4);

      expect(BgmPlan.fromJson(plan.toJson()).segments.single.volume, 0.4);
    });

    test('老存档没有这个字段时用默认值', () {
      final plan = BgmPlan.fromJson([
        {
          'startShot': 0,
          'endShot': 2,
          'material': _a.toJson(),
          'fit': BgmFit.loop.name,
        }
      ]);

      expect(plan.segments.single.volume, BgmSegment.defaultVolume);
    });

    test('存档里的音量是脏数据时夹回合法范围', () {
      final plan = BgmPlan.fromJson([
        {
          'startShot': 0,
          'endShot': 2,
          'material': _a.toJson(),
          'fit': BgmFit.loop.name,
          'volume': 99,
        }
      ]);

      expect(plan.segments.single.volume, 1.0);
    });
  });

  group('音量要真的传到 ffmpeg', () {
    test('混音命令用的是这一段的音量，不是写死的默认值', () {
      final args = ExportCommands.mixBgm(
        voice: '/v.wav',
        bgm: '/b.mp3',
        out: '/o.wav',
        startMs: 0,
        durationMs: 5000,
        bgmVolume: 0.4,
      );

      expect(args.join(' '), contains('volume=0.4'));
    });
  });
}
