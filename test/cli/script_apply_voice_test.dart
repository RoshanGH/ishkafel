import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/script_apply.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/script/sound_mix.dart';

/// Agent 改得了「这个片子听起来是什么样」吗。
///
/// 界面上人能改的，Agent 就该能改——否则人让它「把全片换成云希」时，
/// 它只能回一句「做不了」。这一组是本片基调与三轨混音台的写入校验。
void main() {
  final doc = ScriptDoc([
    ScriptLine.create(text: '第一句'),
    ScriptLine.create(text: ''),
    ScriptLine.create(text: '第三句'),
  ]);

  group('本片基调', () {
    test('给音色和语速都行，只给一个也行', () {
      expect(
          validateBaselineSubmission(
              doc: doc, voiceId: '云希', speechRate: null),
          isEmpty);
      expect(
          validateBaselineSubmission(doc: doc, voiceId: null, speechRate: 25),
          isEmpty);
    });

    test('一个都不给就是空提交——不当成「什么都不改」，直接拒', () {
      expect(
          validateBaselineSubmission(
              doc: doc, voiceId: null, speechRate: null),
          hasLength(1));
    });

    test('语速超出火山口径就拒，并说清范围', () {
      final issues =
          validateBaselineSubmission(doc: doc, voiceId: null, speechRate: 500);
      expect(issues, hasLength(1));
      expect(issues.single.message, contains('-50'));
    });

    test('音色 id 不能是空串——那是「没设」的另一种写法，会静默生效', () {
      expect(
          validateBaselineSubmission(doc: doc, voiceId: '  ', speechRate: null),
          hasLength(1));
    });
  });

  group('逐行音色/语速', () {
    test('行号在范围内、值合法就通过', () {
      expect(
          validateLineVoiceSubmission(doc: doc, edits: const [
            (lineIndex: 0, voiceId: '云希', speechRate: null),
            (lineIndex: 2, voiceId: null, speechRate: 25),
          ]),
          isEmpty);
    });

    test('画面行没有配音——改它的音色是无效操作，要点名而不是静默忽略', () {
      final issues = validateLineVoiceSubmission(doc: doc, edits: const [
        (lineIndex: 1, voiceId: '云希', speechRate: null),
      ]);
      expect(issues, hasLength(1));
      expect(issues.single.message, contains('画面行'));
    });

    test('行号越界就拒', () {
      expect(
          validateLineVoiceSubmission(doc: doc, edits: const [
            (lineIndex: 9, voiceId: '云希', speechRate: null),
          ]),
          hasLength(1));
    });

    test('多个问题一次报完，不是报一条改一条', () {
      expect(
          validateLineVoiceSubmission(doc: doc, edits: const [
            (lineIndex: 9, voiceId: '云希', speechRate: null),
            (lineIndex: 1, voiceId: '云希', speechRate: null),
          ]),
          hasLength(2));
    });
  });

  group('三轨混音台', () {
    test('三条轨的音量都在 0~1 就通过', () {
      expect(
          validateMixSubmission(
              doc: doc,
              mix: const SoundMix(source: 0.5, voice: 1.0, bgm: 0.3)),
          isEmpty);
    });

    test('闪避电平也要在 0~1', () {
      expect(
          validateMixSubmission(
              doc: doc, mix: const SoundMix(duckedSourceVolume: 0.2)),
          isEmpty);
    });

    test('把三条轨全静音要拦一下——成片会是一段哑片，多半是搞错了', () {
      final issues = validateMixSubmission(
          doc: doc,
          mix: const SoundMix(
              sourceMuted: true, voiceMuted: true, bgmMuted: true));
      expect(issues, hasLength(1));
      expect(issues.single.message, contains('哑'));
    });
  });
}
