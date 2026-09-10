import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/material_audio.dart';
import 'package:ishkafel/core/audio/source_audio.dart';

/// 「原片这一镜的声音」：两级设置 + 一个「自动」态。
///
/// 用户 2026-09-10：「我需要把参考视频的声音也拆开。这样我就可以用替换分镜的
/// 原声，加上参考分镜的人声或者背景声，排列组合由我自己选。」
void main() {
  group('自动是第五种状态，不是第五个档位', () {
    test('两级都没设 → 自动（走老逻辑）', () {
      expect(
          resolveSourceAudio(
              replaced: true, taskDefault: SourceAudioSetting.auto),
          isNull);
    });

    test('没换素材的镜头一律自动——那种镜头上没有可选的余地', () {
      expect(
          resolveSourceAudio(
            replaced: false,
            taskDefault:
                const SourceAudioSetting(mode: MaterialAudioMode.vocals),
            shotMode: MaterialAudioMode.background,
          ),
          isNull);
    });

    test('全片设了、镜头没设 → 跟随全片', () {
      final r = resolveSourceAudio(
        replaced: true,
        taskDefault: const SourceAudioSetting(mode: MaterialAudioMode.vocals),
      );
      expect(r?.mode, MaterialAudioMode.vocals);
      expect(r?.volume, 1.0, reason: '原片这一路是主体，默认满音量');
    });

    test('镜头单独设的压过全片', () {
      final r = resolveSourceAudio(
        replaced: true,
        taskDefault: const SourceAudioSetting(mode: MaterialAudioMode.vocals),
        shotMode: MaterialAudioMode.none,
        shotVolume: 0.4,
      );
      expect(r?.mode, MaterialAudioMode.none);
      expect(r?.volume, 0.4);
    });
  });

  group('存档', () {
    test('自动存出来不带档位，读回来还是自动', () {
      final json = SourceAudioSetting.auto.toJson();
      expect(json.containsKey('mode'), isFalse);
      expect(SourceAudioSetting.fromJson(json).isAuto, isTrue);
    });

    test('没有这个字段的老存档读成自动——老任务的声音一个字节都不该变', () {
      expect(SourceAudioSetting.fromJson(null), SourceAudioSetting.auto);
    });

    test('设过的档位存得住', () {
      const s =
          SourceAudioSetting(mode: MaterialAudioMode.background, volume: 0.6);
      expect(SourceAudioSetting.fromJson(s.toJson()), s);
    });

    test('回到自动：copyWith 的 ?? 做不到，用 toAuto', () {
      const s = SourceAudioSetting(mode: MaterialAudioMode.vocals, volume: 0.5);
      expect(s.toAuto().isAuto, isTrue);
      expect(s.toAuto().volume, 0.5, reason: '音量不该被顺手清掉');
    });
  });

  test('新任务的替换分镜默认放原声，存量任务的缺省仍是不播放', () {
    expect(newTaskMaterialAudio.mode, MaterialAudioMode.original);
    expect(MaterialAudioSetting.off.mode, MaterialAudioMode.none);
  });

  test('四个档位在原片语境下各有各的说法，不跟素材共用一份文案', () {
    for (final m in MaterialAudioMode.values) {
      expect(m.sourceHint, isNotEmpty);
      expect(m.sourceHint, isNot(m.hint));
    }
  });
}
