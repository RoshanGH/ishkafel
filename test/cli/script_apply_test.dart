import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/script_apply.dart';
import 'package:ishkafel/core/script/script_doc.dart';

/// 四类回填的校验器。**整批校验、整批拒绝、一次点全所有问题**——
/// 让调用方改一条提交一次是在浪费双方时间（沿用 apply_command 的既定风格）。
void main() {
  LineVoiceover vo(int ms, {int words = 0}) => LineVoiceover(
        audioPath: '/vo.mp3',
        durationMs: ms,
        sourceText: '词' * (words == 0 ? 1 : words),
        voiceId: 'v',
        speechRate: 0,
        words: [
          for (var i = 0; i < words; i++)
            VoiceWord(
                text: '词',
                startMs: (i * ms / words).round(),
                endMs: (i * ms / words).round() + 100),
        ],
      );

  ScriptDoc doc() => ScriptDoc([
        ScriptLine.create(text: '第一句')
            .withShots(const [
              LineShot(materialId: 1, name: 'a', durationMs: 9000, allocMs: 3000),
            ])
            .withVoiceover(vo(3000, words: 6)),
        ScriptLine.create(text: '第二句')
            .withVoiceover(vo(8880, words: 40)),
      ]);

  group('挑镜回填', () {
    test('合法就放行', () {
      expect(
          validateShotsSubmission(
              doc: doc(),
              picks: [(lineIndex: 1, materialIds: [500])],
              offered: {500: 9000}),
          isEmpty);
    });

    test('选了候选之外的 id：拒绝并点名', () {
      final issues = validateShotsSubmission(
          doc: doc(),
          picks: [(lineIndex: 1, materialIds: [999])],
          offered: {500: 9000});
      // 会同时报「不在候选里」和「凑不满这一行」——一次点全，不是只报第一条
      expect(issues.map((i) => i.message).join(), contains('不在候选里'));
    });

    test('镜头凑不满这一行：说清差多少', () {
      final issues = validateShotsSubmission(
          doc: doc(),
          picks: [(lineIndex: 1, materialIds: [500])],
          offered: {500: 4200});
      expect(issues.single.message, allOf(contains('4.2'), contains('8.9')));
    });

    test('同一行重复选同一条素材：拒绝', () {
      final issues = validateShotsSubmission(
          doc: doc(),
          picks: [(lineIndex: 1, materialIds: [500, 500])],
          offered: {500: 9000});
      expect(issues.map((i) => i.message).join(), contains('重复'));
    });

    test('一次点全所有问题，不是遇到第一条就返回', () {
      final issues = validateShotsSubmission(doc: doc(), picks: [
        (lineIndex: 9, materialIds: [500]),
        (lineIndex: 1, materialIds: [999]),
      ], offered: {500: 9000});
      expect(issues.length, greaterThanOrEqualTo(2),
          reason: '两行各自的问题都要点出来');
    });
  });

  group('断句回填', () {
    test('合法切点放行', () {
      expect(
          validateSubtitleSubmission(
              doc: doc(), submissions: [(lineIndex: 1, cuts: [12, 26])]),
          isEmpty);
    });

    test('切点超出范围：说清这句有几个字', () {
      final issues = validateSubtitleSubmission(
          doc: doc(), submissions: [(lineIndex: 1, cuts: [80])]);
      expect(issues.map((i) => i.message).join(),
          allOf(contains('80'), contains('40')));
    });

    test('不是递增：拒绝', () {
      final issues = validateSubtitleSubmission(
          doc: doc(), submissions: [(lineIndex: 1, cuts: [20, 10])]);
      expect(issues.map((i) => i.message).join(), contains('递增'));
    });

    test('切出只有两三个字的屏：拒绝——闪一下就过去，看着像坏了', () {
      final issues = validateSubtitleSubmission(
          doc: doc(), submissions: [(lineIndex: 1, cuts: [2, 4])]);
      expect(issues, isNotEmpty);
    });

    test('没有逐字时间的行：拒绝，不假装能断', () {
      final untimed = ScriptDoc([
        ScriptLine.create(text: '台词').withVoiceover(vo(3000)),
      ]);
      final issues = validateSubtitleSubmission(
          doc: untimed, submissions: [(lineIndex: 0, cuts: [2])]);
      expect(issues.single.message, contains('重新生成配音'));
    });
  });

  group('时长回填', () {
    test('总和等于配音时长就放行', () {
      final d = doc();
      final withShots = d.setShotsById(d.lines[1].id, const [
        LineShot(materialId: 5, name: 'x', durationMs: 9000, allocMs: 4000),
        LineShot(materialId: 6, name: 'y', durationMs: 9000, allocMs: 4880),
      ]);
      expect(
          validateAllocSubmission(
              doc: withShots,
              submissions: [(lineIndex: 1, allocMs: [4000, 4880])]),
          isEmpty);
    });

    test('总和对不上：说清差多少会错位', () {
      final d = doc();
      final withShots = d.setShotsById(d.lines[1].id, const [
        LineShot(materialId: 5, name: 'x', durationMs: 9000, allocMs: 8880),
      ]);
      final issues = validateAllocSubmission(
          doc: withShots, submissions: [(lineIndex: 1, allocMs: [8000])]);
      expect(issues.map((i) => i.message).join(),
          allOf(contains('8.9'), contains('错位')));
    });

    test('某一镜超过素材能出的长度：拒绝——成片里会定格', () {
      final d = doc();
      final withShots = d.setShotsById(d.lines[1].id, const [
        LineShot(materialId: 5, name: 'x', durationMs: 2000, allocMs: 8880),
      ]);
      final issues = validateAllocSubmission(
          doc: withShots, submissions: [(lineIndex: 1, allocMs: [8880])]);
      expect(issues.map((i) => i.message).join(), contains('只能出'));
    });

    test('容许一帧的取整零头', () {
      final d = doc();
      final withShots = d.setShotsById(d.lines[1].id, const [
        LineShot(materialId: 5, name: 'x', durationMs: 9000, allocMs: 8880),
      ]);
      expect(
          validateAllocSubmission(
              doc: withShots, submissions: [(lineIndex: 1, allocMs: [8881])]),
          isEmpty);
    });
  });

  group('配乐回填', () {
    test('连续铺满全片就放行', () {
      expect(
          validateBgmSubmission(doc: doc(), submissions: [
            (startLine: 0, endLine: 0, materialId: 1, volume: 0.25),
            (startLine: 1, endLine: 1, materialId: 2, volume: 0.25),
          ], offered: {1, 2}),
          isEmpty);
    });

    test('留了空档：拒绝——配乐轨是整片切成几段，不能有洞', () {
      final issues = validateBgmSubmission(doc: doc(), submissions: [
        (startLine: 0, endLine: 0, materialId: 1, volume: 0.25),
      ], offered: {1});
      expect(issues.map((i) => i.message).join(), contains('没有配乐段'));
    });

    test('区间重叠：拒绝', () {
      final issues = validateBgmSubmission(doc: doc(), submissions: [
        (startLine: 0, endLine: 1, materialId: 1, volume: 0.25),
        (startLine: 1, endLine: 1, materialId: 2, volume: 0.25),
      ], offered: {1, 2});
      expect(issues.map((i) => i.message).join(), contains('重叠'));
    });

    test('曲子不在候选里 / 音量越界：都要点名', () {
      final issues = validateBgmSubmission(doc: doc(), submissions: [
        (startLine: 0, endLine: 1, materialId: 999, volume: 1.8),
      ], offered: {1});
      expect(issues.length, greaterThanOrEqualTo(2),
          reason: '曲子不在候选、音量越界——两条都要点出来');
    });
  });
}
