import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/audio_track_builder.dart';
import 'package:ishkafel/core/export/export_commands.dart';

/// 改了「怎么把一层声音叠上去」的规则，**旧产物一个都不许再被命中**。
///
/// 中间产物按内容指纹缓存（见 [RenderedCache]），而指纹是用入参拼的：
/// 素材路径、位置、时长、倍率、音量。规则本身不在里面——于是 2026-09-11
/// 改完滤镜链之后，盘上那些**按错规则渲出来的** `mix_material_*.wav`
/// 入参一个没变，键也就一个没变，下次导出照样命中。用户装了新版、重新导出，
/// 听到的还是老毛病，而哪儿都不报错。
///
/// 所以规则版本必须进键。CLAUDE.md 那条写的就是这件事：「缓存复用一律按内容
/// 指纹判定，绝不能按『文件名存在』就当命中——那会静默放出上一个版本的内容」。
void main() {
  group('合成规则的版本要进缓存键', () {
    test('素材原声的键带着规则版本', () {
      final key = AudioTrackBuilder.materialMixKey(
        base: 'concat|a|b',
        materialPath: '/m/71.mp4',
        startMs: 5000,
        durationMs: 2000,
        speedFactor: 1.5,
        trimStartMs: 0,
        volume: 0.25,
      );

      expect(key, contains(ExportCommands.mixRuleVersion));
    });

    test('配乐的键带着规则版本', () {
      final key = AudioTrackBuilder.bgmMixKey(
        base: 'concat|a|b',
        materialId: 9,
        startMs: 5000,
        endMs: 8000,
        volume: 0.25,
      );

      expect(key, contains(ExportCommands.mixRuleVersion));
    });

    test('规则版本不一样，键就不一样——旧产物于是命不中', () {
      String keyAt(String version) => AudioTrackBuilder.materialMixKey(
            base: 'concat|a|b',
            materialPath: '/m/71.mp4',
            startMs: 5000,
            durationMs: 2000,
            speedFactor: 1.5,
            trimStartMs: 0,
            volume: 0.25,
            version: version,
          );

      expect(keyAt('v1'), isNot(keyAt('v2')));
    });

    test('入参变了键照样要变——版本号不能把原来的判定盖掉', () {
      String keyAtVolume(double volume) => AudioTrackBuilder.materialMixKey(
            base: 'concat|a|b',
            materialPath: '/m/71.mp4',
            startMs: 5000,
            durationMs: 2000,
            speedFactor: 1.5,
            trimStartMs: 0,
            volume: volume,
          );

      expect(keyAtVolume(0.25), isNot(keyAtVolume(0.5)));
    });
  });
}
