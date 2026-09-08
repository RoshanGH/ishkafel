import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/material_audio.dart';

void main() {
  group('替换分镜的声音：四选一', () {
    test('默认不播——升级一版不该让存量任务的成片突然多出一层声音', () {
      expect(MaterialAudioSetting.off.mode, MaterialAudioMode.none);
      expect(
          resolveMaterialAudio(taskDefault: MaterialAudioSetting.off).mode,
          MaterialAudioMode.none);
    });

    test('四档都在：不播 / 人声 / 背景声 / 原声', () {
      expect(MaterialAudioMode.values.map((m) => m.name).toSet(),
          {'none', 'vocals', 'background', 'original'});
    });

    test('人声和背景声要先分离，原声不用', () {
      expect(MaterialAudioMode.vocals.needsSeparation, isTrue);
      expect(MaterialAudioMode.background.needsSeparation, isTrue);
      expect(MaterialAudioMode.original.needsSeparation, isFalse);
      expect(MaterialAudioMode.none.needsSeparation, isFalse);
    });

    test('要不要出声：只有「不播」不出声', () {
      expect(MaterialAudioMode.none.audible, isFalse);
      expect(MaterialAudioMode.vocals.audible, isTrue);
      expect(MaterialAudioMode.background.audible, isTrue);
      expect(MaterialAudioMode.original.audible, isTrue);
    });

    test('每一档都有一句人话——界面和 CLI 共用同一份说法', () {
      for (final m in MaterialAudioMode.values) {
        expect(m.label, isNotEmpty);
      }
      expect(MaterialAudioMode.background.label, contains('背景'));
    });
  });

  group('任务打底、镜头覆盖', () {
    test('镜头没设过就跟任务走', () {
      const task = MaterialAudioSetting(
          mode: MaterialAudioMode.background, volume: 0.4);

      final r = resolveMaterialAudio(taskDefault: task);

      expect(r.mode, MaterialAudioMode.background);
      expect(r.volume, 0.4);
    });

    test('镜头单独改档位，盖过任务的', () {
      const task = MaterialAudioSetting(mode: MaterialAudioMode.original);

      final r = resolveMaterialAudio(
          taskDefault: task, shotMode: MaterialAudioMode.vocals);

      expect(r.mode, MaterialAudioMode.vocals);
    });

    test('镜头单独设成「不播」，盖过全片的「原声」', () {
      const task = MaterialAudioSetting(mode: MaterialAudioMode.original);

      final r = resolveMaterialAudio(
          taskDefault: task, shotMode: MaterialAudioMode.none);

      expect(r.mode, MaterialAudioMode.none,
          reason: 'null 才是「跟随全片」，none 是明确要求这一镜别出声');
    });

    test('镜头可以只覆盖音量、不动档位', () {
      const task = MaterialAudioSetting(
          mode: MaterialAudioMode.background, volume: 0.25);

      final r = resolveMaterialAudio(taskDefault: task, shotVolume: 0.8);

      expect(r.mode, MaterialAudioMode.background);
      expect(r.volume, 0.8);
    });

    test('默认音量跟配乐一样是 25%——它叠在口播上，给大了会盖住台词', () {
      expect(MaterialAudioSetting.defaultVolume, 0.25);
    });

    test('音量夹在 0~1，不接受越界值', () {
      expect(
          const MaterialAudioSetting(
                  mode: MaterialAudioMode.original, volume: 3)
              .volume,
          1.0);
      expect(
          const MaterialAudioSetting(
                  mode: MaterialAudioMode.original, volume: -1)
              .volume,
          0.0);
    });
  });

  group('存量存档要读得回来', () {
    test('老的 keep:true 读成「原声」——那时就只有这一种行为', () {
      final s = MaterialAudioSetting.fromJson({'keep': true, 'volume': 0.3});

      expect(s.mode, MaterialAudioMode.original);
      expect(s.volume, 0.3);
    });

    test('老的 keep:false 读成「不播」', () {
      expect(MaterialAudioSetting.fromJson({'keep': false}).mode,
          MaterialAudioMode.none);
    });

    test('没有这个字段的老存档一律不播', () {
      expect(MaterialAudioSetting.fromJson(null).mode, MaterialAudioMode.none);
    });

    test('认不出的档位名不许崩，退回不播', () {
      expect(MaterialAudioSetting.fromJson({'mode': '天书'}).mode,
          MaterialAudioMode.none);
    });

    test('新写的存档存的是档位名', () {
      const s = MaterialAudioSetting(mode: MaterialAudioMode.background);

      expect(s.toJson()['mode'], 'background');
    });
  });

  group('变速：声音要跟画面同步', () {
    test('几乎不变速时不插滤镜——白走一道只会掉音质', () {
      expect(atempoChain(1.0), isEmpty);
      expect(atempoChain(1.0001), isEmpty);
    });

    test('常见倍率直接一节', () {
      expect(atempoChain(1.5), ['atempo=1.5']);
      expect(atempoChain(0.8), ['atempo=0.8']);
    });

    test('超出单节范围时拆成几节连乘（atempo 单节只认 0.5~2.0）', () {
      final chain = atempoChain(2.9);

      expect(chain.length, greaterThan(1));
      final product = chain
          .map((f) => double.parse(f.split('=')[1]))
          .reduce((a, b) => a * b);
      expect(product, closeTo(2.9, 0.001));
      for (final f in chain) {
        final v = double.parse(f.split('=')[1]);
        expect(v, inInclusiveRange(0.5, 2.0));
      }
    });

    test('放得很慢也拆得开', () {
      final chain = atempoChain(0.3);

      final product = chain
          .map((f) => double.parse(f.split('=')[1]))
          .reduce((a, b) => a * b);
      expect(product, closeTo(0.3, 0.001));
      for (final f in chain) {
        final v = double.parse(f.split('=')[1]);
        expect(v, inInclusiveRange(0.5, 2.0));
      }
    });
  });
}
