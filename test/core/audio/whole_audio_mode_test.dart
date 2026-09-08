import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/material_audio.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';

/// **整体替换的声音默认是「原声」，镜头替换默认是「不播放」——两边不一样，
/// 而且必须不一样。**
///
/// 整体替换是「画面和声音一起换掉」，那一段的口播本来就来自素材；
/// 镜头替换只换画面，口播还是原片的，素材的声音是额外叠上去的一层。
///
/// 把整体替换也默认成「不播放」，存量任务导出来会突然整段没声音。
SemanticUnit _u({MaterialAudioMode? mode, double? volume}) => SemanticUnit(
      index: 0,
      startMs: 0,
      endMs: 1000,
      transcript: 'U1',
      wholeAudioMode: mode,
      wholeAudioVolume: volume,
    );

void main() {
  group('整体替换的声音', () {
    test('没设过就是原声、满音量——存量任务导出来一个字节都不变', () {
      final s = resolveWholeAudio(_u());

      expect(s.mode, MaterialAudioMode.original);
      expect(s.volume, 1.0);
    });

    test('可以改成不播放——片头插的那一段只要画面，声音交给配乐', () {
      final s = resolveWholeAudio(_u(mode: MaterialAudioMode.none));

      expect(s.mode, MaterialAudioMode.none);
    });

    test('可以只要背景声——素材自己带口播时不至于两个人一起说话', () {
      final s = resolveWholeAudio(_u(mode: MaterialAudioMode.background));

      expect(s.mode, MaterialAudioMode.background);
      expect(s.mode.needsSeparation, isTrue);
    });

    test('音量可以单独压低', () {
      expect(resolveWholeAudio(_u(volume: 0.3)).volume, 0.3);
    });

    test('存量存档没有这两个字段：读回来还是原声满音量', () {
      final unit = SemanticUnit.fromJson({
        'index': 0,
        'startMs': 0,
        'endMs': 1000,
        'transcript': 'U1',
      });

      expect(unit.wholeAudioMode, isNull);
      expect(resolveWholeAudio(unit).mode, MaterialAudioMode.original);
    });

    test('设过就存下来，读回来一致', () {
      final unit = SemanticUnit.fromJson(
          _u(mode: MaterialAudioMode.background, volume: 0.4).toJson());

      expect(unit.wholeAudioMode, MaterialAudioMode.background);
      expect(unit.wholeAudioVolume, 0.4);
    });
  });
}
