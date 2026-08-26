import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/script/script_doc.dart';

/// 本片基调：**默认音色与默认语速**。
///
/// 缺这一层的后果是真机上的两件事：一是第一次生成配音只能撞运气用系统默认，
/// 不对就白烧一次 TTS；二是想换音色得一行行点 28 次。
///
/// 与字幕样式同一个模式：行上没设就跟随本片基调，设过就以行为准。
/// **有效值只有一处算**——今天刚因为「显示和播放各算各的」出过静音 bug。
void main() {
  _unifyTests();

  ScriptDoc docWith({
    String? defaultVoiceId,
    int? defaultSpeechRate,
    String? lineVoiceId,
    int? lineSpeechRate,
  }) {
    var line = ScriptLine.create(text: '第一句');
    if (lineVoiceId != null) line = line.withVoiceId(lineVoiceId);
    if (lineSpeechRate != null) line = line.withSpeechRate(lineSpeechRate);
    return ScriptDoc([line],
        defaultVoiceId: defaultVoiceId,
        defaultSpeechRate: defaultSpeechRate ?? 0);
  }

  group('有效音色', () {
    test('行上没选就跟随本片基调', () {
      final doc = docWith(defaultVoiceId: '云希');
      expect(doc.voiceIdOf(doc.lines.first), '云希');
    });

    test('行上选过就以行为准——单独试音色的那一行不该被基调顶掉', () {
      final doc = docWith(defaultVoiceId: '云希', lineVoiceId: '晓晓');
      expect(doc.voiceIdOf(doc.lines.first), '晓晓');
    });

    test('两边都没有就是 null——这正是「先卡住让人选」的判据', () {
      expect(docWith().voiceIdOf(docWith().lines.first), isNull);
    });
  });

  group('有效语速', () {
    test('行上没设就跟随本片基调', () {
      final doc = docWith(defaultSpeechRate: 20);
      expect(doc.speechRateOf(doc.lines.first), 20);
    });

    test('行上设成 0 是「就要原速」，不是「没设过」', () {
      final doc = docWith(defaultSpeechRate: 20, lineSpeechRate: 0);
      expect(doc.speechRateOf(doc.lines.first), 0,
          reason: '0 必须能压过基调，否则单独调回原速就做不到');
    });

    test('都没设就是 0（原速）', () {
      expect(docWith().speechRateOf(docWith().lines.first), 0);
    });
  });

  group('配音是否过期：要拿**有效值**比，不是行上的值', () {
    test('改了本片音色，已经生成的那些就算过期', () {
      var doc = docWith(defaultVoiceId: '晓晓');
      doc = doc.setVoiceoverById(
          doc.lines.first.id, vo(voiceId: '晓晓', speechRate: 0, text: '第一句'));
      expect(doc.voiceStateOf(doc.lines.first), LineVoiceState.fresh);

      final changed = doc.withDefaultVoiceId('云希');
      expect(changed.voiceStateOf(changed.lines.first), LineVoiceState.stale,
          reason: '基调换了，旧配音就是旧音色——不说出来会混出一条音色分裂的片子');
    });

    test('那一行单独设过音色，就不受基调变化影响', () {
      var doc = docWith(defaultVoiceId: '晓晓', lineVoiceId: '云希');
      doc = doc.setVoiceoverById(
          doc.lines.first.id, vo(voiceId: '云希', speechRate: 0, text: '第一句'));
      final changed = doc.withDefaultVoiceId('小北');
      expect(changed.voiceStateOf(changed.lines.first), LineVoiceState.fresh);
    });

    test('改了本片语速也一样算过期', () {
      var doc = docWith(defaultSpeechRate: 0);
      doc = doc.setVoiceoverById(
          doc.lines.first.id, vo(voiceId: 'v', speechRate: 0, text: '第一句'));
      final changed = doc.withDefaultSpeechRate(30);
      expect(changed.voiceStateOf(changed.lines.first), LineVoiceState.stale);
    });
  });

  group('json 往返', () {
    test('基调不丢', () {
      final doc = docWith(defaultVoiceId: '云希', defaultSpeechRate: 15);
      final back = ScriptDoc.fromJson(doc.toJson());
      expect(back.defaultVoiceId, '云希');
      expect(back.defaultSpeechRate, 15);
    });

    test('老档没有基调：读出来是「还没设过」，行为和以前一样', () {
      final back = ScriptDoc.fromJson({
        'lines': [
          {'id': 'l1', 'text': '台词'}
        ]
      });
      expect(back.defaultVoiceId, isNull);
      expect(back.defaultSpeechRate, 0);
    });
  });
}

LineVoiceover vo({
  required String voiceId,
  required int speechRate,
  required String text,
}) =>
    LineVoiceover(
      audioPath: '/v/a.mp3',
      durationMs: 3000,
      sourceText: text,
      voiceId: voiceId,
      speechRate: speechRate,
    );

/// 「应用到全片」：**设基调 + 清掉各行的单独设定**。
///
/// 只设基调不清覆盖的话，之前单独试过音色的那几行会留在旧音色上，
/// 混出一条前后不一样的片子——而人点的明明是「全片」。
void _unifyTests() {
  group('统一全片音色', () {
    test('设成基调，并清掉各行单独设过的音色', () {
      var doc = ScriptDoc([
        ScriptLine.create(text: '第一句').withVoiceId('晓晓'),
        ScriptLine.create(text: '第二句'),
        ScriptLine.create(text: '第三句').withVoiceId('小北'),
      ]);
      doc = doc.unifyVoice('云希');
      expect(doc.defaultVoiceId, '云希');
      for (final line in doc.lines) {
        expect(line.voiceId, isNull, reason: '清掉覆盖，全片才是真的统一');
        expect(doc.voiceIdOf(line), '云希');
      }
    });

    test('语速同理', () {
      var doc = ScriptDoc([
        ScriptLine.create(text: '第一句').withSpeechRate(50),
        ScriptLine.create(text: '第二句'),
      ]);
      doc = doc.unifySpeechRate(25);
      expect(doc.defaultSpeechRate, 25);
      expect(doc.lines.every((l) => l.speechRate == null), isTrue);
    });

    test('统一之后，已经生成过配音的行全部算过期——要重配', () {
      var doc = ScriptDoc([ScriptLine.create(text: '第一句')]);
      doc = doc.setVoiceoverById(
          doc.lines.first.id, vo(voiceId: '晓晓', speechRate: 0, text: '第一句'));
      doc = doc.unifyVoice('云希');
      expect(doc.voiceStateOf(doc.lines.first), LineVoiceState.stale);
      expect(doc.staleVoiceLines, hasLength(1));
    });

    test('画面行不算在待重配里——它本来就没有配音', () {
      var doc = ScriptDoc([
        ScriptLine.create(text: '第一句'),
        ScriptLine.create(text: ''),
      ]);
      doc = doc.setVoiceoverById(
          doc.lines.first.id, vo(voiceId: '晓晓', speechRate: 0, text: '第一句'));
      doc = doc.unifyVoice('云希');
      expect(doc.staleVoiceLines, hasLength(1));
    });
  });
}
