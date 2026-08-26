import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/script/sound_mix.dart';

/// 三条声音轨的总控：原声 / 配音 / 配乐。
///
/// 用户的心智就是一张混音台——「三条轨可能同时播放，也可能调整其中一个，
/// 关闭也好，声音大小也好」。此前只有一根滑杆，还名不副实：它叫「原声」、
/// 摆在主预览下面像总音量，实际调的是「配音行没单独设时原声压到多少」，
/// 所以拉它对画面行永远没反应。
void main() {
  _docTests();

  group('默认值 = 升级前的行为，一个字节不改', () {
    test('三条轨默认满音量、都不静音', () {
      const mix = SoundMix();
      expect(mix.source, 1.0);
      expect(mix.voice, 1.0);
      expect(mix.bgm, 1.0);
      expect(mix.sourceMuted, isFalse);
    });

    test('默认开启「有口播时压低原声」，压到 0——原声会和口播叠成两份', () {
      const mix = SoundMix();
      expect(mix.duckSourceUnderVoice, isTrue);
      expect(mix.duckedSourceVolume, 0.0);
    });
  });

  group('有效音量：静音钮不吃掉原来的音量', () {
    test('静音时输出 0，但记着原来拉到哪儿——再点一下要能回去', () {
      const mix = SoundMix(source: 0.75, sourceMuted: true);
      expect(mix.effectiveSource, 0.0);
      expect(mix.source, 0.75, reason: '滑杆位置不能被静音钮抹掉');
    });

    test('取消静音就回到原来的位置', () {
      const mix = SoundMix(source: 0.75, sourceMuted: true);
      expect(mix.withSourceMuted(false).effectiveSource, 0.75);
    });

    test('三条轨各管各的', () {
      const mix = SoundMix(voice: 0.5, bgmMuted: true);
      expect(mix.effectiveSource, 1.0);
      expect(mix.effectiveVoice, 0.5);
      expect(mix.effectiveBgm, 0.0);
    });
  });

  group('越界一律夹回 0~1', () {
    test('超出范围的值不能存进去', () {
      expect(const SoundMix(source: 3).source, 1.0);
      expect(const SoundMix(voice: -1).voice, 0.0);
      expect(const SoundMix(duckedSourceVolume: 9).duckedSourceVolume, 1.0);
    });
  });

  group('json 往返', () {
    test('调过的值不丢', () {
      const mix = SoundMix(
        source: 0.75,
        voice: 0.9,
        bgm: 0.45,
        bgmMuted: true,
        duckSourceUnderVoice: false,
        duckedSourceVolume: 0.2,
      );
      final back = SoundMix.fromJson(mix.toJson());
      expect(back.source, 0.75);
      expect(back.voice, 0.9);
      expect(back.bgm, 0.45);
      expect(back.bgmMuted, isTrue);
      expect(back.duckSourceUnderVoice, isFalse);
      expect(back.duckedSourceVolume, 0.2);
    });

    test('全默认时不往 json 里写垃圾——老档打开不该凭空多出一堆字段', () {
      expect(const SoundMix().toJson(), isEmpty);
    });

    test('读不懂的 json 当默认，不炸', () {
      expect(SoundMix.fromJson(null).source, 1.0);
      expect(SoundMix.fromJson('乱写').voice, 1.0);
    });
  });
}

/// 接进 ScriptDoc：**老档的声音一个字节不能变**。
void _docTests() {
  group('ScriptDoc 上的混音台', () {
    final visual = ScriptLine.create(text: '').withShots(const [
      LineShot(materialId: 1, name: 'a', durationMs: 9000, allocMs: 4000),
    ]);
    final voiced = ScriptLine.create(text: '第一句').withShots(const [
      LineShot(materialId: 2, name: 'b', durationMs: 9000, allocMs: 4000),
    ]);

    test('老档只有 sourceVolume：读成「口播时压到多少」，行为和以前一样', () {
      final doc = ScriptDoc.fromJson({
        'sourceVolume': 0.35,
        'lines': [
          {
            'id': 'l1',
            'text': '台词',
            'shots': [
              {'materialId': 1, 'name': 'a'}
            ]
          }
        ]
      });
      expect(doc.mix.duckedSourceVolume, 0.35);
      expect(doc.mix.source, 1.0, reason: '总音量是新概念，老档一律满');
      // 配音行没单独设 → 压到 0.35，与升级前一模一样
      expect(doc.sourceVolumeFor(doc.lines.first, doc.lines.first.shots.first),
          0.35);
    });

    test('总音量对**画面行**也生效——这正是用户拉不动的那根', () {
      final doc = ScriptDoc([visual]).withMix(const SoundMix(source: 0.5));
      expect(doc.sourceVolumeFor(visual, visual.shots.first), 0.5);
    });

    test('总音量乘在逐镜设定上——单独设过的镜头也跟着变', () {
      const quiet = LineShot(
          materialId: 1,
          name: 'a',
          durationMs: 9000,
          allocMs: 4000,
          sourceVolume: 0.4);
      final line = ScriptLine.create(text: '').withShots(const [quiet]);
      final doc = ScriptDoc([line]).withMix(const SoundMix(source: 0.5));
      expect(doc.sourceVolumeFor(line, quiet), closeTo(0.2, 1e-9));
    });

    test('原声静音：所有行都哑，不管逐镜设了多少', () {
      const loud = LineShot(
          materialId: 1,
          name: 'a',
          durationMs: 9000,
          allocMs: 4000,
          sourceVolume: 1.0);
      final line = ScriptLine.create(text: '').withShots(const [loud]);
      final doc = ScriptDoc([line]).withMix(const SoundMix(sourceMuted: true));
      expect(doc.sourceVolumeFor(line, loud), 0.0);
    });

    test('关掉闪避：配音行的原声不再被压，回到满音量', () {
      final doc = ScriptDoc([voiced])
          .withMix(const SoundMix(duckSourceUnderVoice: false));
      expect(doc.sourceVolumeFor(voiced, voiced.shots.first), 1.0);
    });

    test('配音行单独设过就不闪避——它是明确的指定，压过默认', () {
      const set = LineShot(
          materialId: 2,
          name: 'b',
          durationMs: 9000,
          allocMs: 4000,
          sourceVolume: 0.8);
      final line = ScriptLine.create(text: '第一句').withShots(const [set]);
      final doc = ScriptDoc([line]);
      expect(doc.sourceVolumeFor(line, set), 0.8);
    });

    test('配音轨与配乐轨也有总音量', () {
      final doc = ScriptDoc([voiced])
          .withMix(const SoundMix(voice: 0.6, bgm: 0.3));
      expect(doc.voiceVolume, 0.6);
      expect(doc.bgmVolumeOf(0.5), closeTo(0.15, 1e-9));
    });

    test('json 往返：混音台不丢，且老字段照样写出去（降级能打开）', () {
      final doc = ScriptDoc([voiced])
          .withMix(const SoundMix(source: 0.5, duckedSourceVolume: 0.2));
      final back = ScriptDoc.fromJson(doc.toJson());
      expect(back.mix.source, 0.5);
      expect(back.mix.duckedSourceVolume, 0.2);
      expect(doc.toJson()['sourceVolume'], 0.2,
          reason: '老字段仍写出闪避电平——旧版本打开还是原来的行为');
    });
  });
}
