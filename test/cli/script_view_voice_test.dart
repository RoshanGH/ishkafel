import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/script_view.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/script/sound_mix.dart';

/// Agent 读得到「这个片子听起来是什么样」吗。
///
/// 每加一个功能，Agent 侧要同步。这一组盯的是最近几版新增的东西：
/// 本片基调（音色/语速）、三轨混音台、行上单独设过的音色/语速。
/// 读不到，Agent 就只能瞎猜——或者更糟，拿着过期的判断直接导出。
void main() {
  RenewTask taskWith(ScriptDoc doc) => RenewTask(
        id: 't1',
        name: '片子',
        sourcePath: null,
        status: RenewTaskStatus.ready,
        createdAt: DateTime.utc(2026, 8, 26),
        updatedAt: DateTime.utc(2026, 8, 26),
        units: const [],
        script: doc,
      );

  LineVoiceover vo(String voiceId, {int rate = 0, String text = '第一句'}) =>
      LineVoiceover(
        audioPath: '/v/a.mp3',
        durationMs: 3000,
        sourceText: text,
        voiceId: voiceId,
        speechRate: rate,
      );

  group('本片基调要能读到', () {
    test('音色与语速的基调出现在输出里', () {
      final doc = ScriptDoc([ScriptLine.create(text: '第一句')])
          .withDefaultVoiceId('云希')
          .withDefaultSpeechRate(25);
      final json = scriptTaskJson(taskWith(doc));
      expect(json['defaultVoiceId'], '云希');
      expect(json['defaultSpeechRate'], 25);
    });

    test('没定过音色时如实给 null——这是「该先问人」的信号', () {
      final json = scriptTaskJson(taskWith(ScriptDoc.empty()));
      expect(json.containsKey('defaultVoiceId'), isTrue);
      expect(json['defaultVoiceId'], isNull);
    });
  });

  group('三轨混音台要能读到', () {
    test('三条轨的音量、静音、闪避都给出来', () {
      final doc = ScriptDoc([ScriptLine.create(text: '第一句')]).withMix(
          const SoundMix(
              source: 0.5,
              voice: 0.9,
              bgm: 0.3,
              bgmMuted: true,
              duckedSourceVolume: 0.2));
      final mix = scriptTaskJson(taskWith(doc))['sound'] as Map;
      expect(mix['source'], 0.5);
      expect(mix['voice'], 0.9);
      expect(mix['bgm'], 0.3);
      expect(mix['bgmMuted'], isTrue);
      expect(mix['duckSourceUnderVoice'], isTrue);
      expect(mix['duckedSourceVolume'], 0.2);
    });
  });

  group('行上单独设过的要能读到', () {
    test('行级音色与语速出现在行里', () {
      final doc = ScriptDoc([
        ScriptLine.create(text: '第一句').withVoiceId('晓晓').withSpeechRate(50),
      ]);
      final line = (scriptTaskJson(taskWith(doc))['lines'] as List).first
          as Map<String, dynamic>;
      expect(line['voiceId'], '晓晓');
      expect(line['speechRate'], 50);
    });

    test('跟随本片基调的行给出**有效值**，并标明是跟随来的', () {
      final doc = ScriptDoc([ScriptLine.create(text: '第一句')])
          .withDefaultVoiceId('云希');
      final line = (scriptTaskJson(taskWith(doc))['lines'] as List).first
          as Map<String, dynamic>;
      expect(line['voiceId'], '云希', reason: '给有效值，Agent 才知道会用谁去配');
      expect(line['voiceFollowsDoc'], isTrue, reason: '但要说清这是跟随来的');
    });
  });

  group('配音过期判定必须拿有效值算', () {
    test('换了本片基调，已生成的那些要报 stale', () {
      var doc = ScriptDoc([ScriptLine.create(text: '第一句')])
          .withDefaultVoiceId('晓晓');
      doc = doc.setVoiceoverById(doc.lines.first.id, vo('晓晓'));
      doc = doc.withDefaultVoiceId('云希');

      final line = (scriptTaskJson(taskWith(doc))['lines'] as List).first
          as Map<String, dynamic>;
      final voice = line['voice'] as Map;
      expect(voice['state'], 'stale',
          reason: '界面说过期、CLI 说新鲜的话，Agent 会直接拿旧音色导出去');
    });

    test('那一行单独设过音色就不受基调变化影响', () {
      var doc = ScriptDoc([
        ScriptLine.create(text: '第一句').withVoiceId('云希'),
      ]).withDefaultVoiceId('晓晓');
      doc = doc.setVoiceoverById(doc.lines.first.id, vo('云希'));
      doc = doc.withDefaultVoiceId('小北');

      final line = (scriptTaskJson(taskWith(doc))['lines'] as List).first
          as Map<String, dynamic>;
      expect((line['voice'] as Map)['state'], 'fresh');
    });
  });
}
