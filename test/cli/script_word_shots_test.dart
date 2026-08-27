import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/script_apply.dart';
import 'package:ishkafel/cli/script_view.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/script/shot_allocation.dart';

/// 划词建镜的 Agent 侧。**人能干的，Agent 都要能干**。
///
/// 人在界面上选中「如果你觉得有点贵」→ 那一镜就是这几个字的朗读时长。
/// Agent 要做同一件事，就得能读到每个字落在哪、哪些字已被占，
/// 还得能提交一个词区间。
void main() {
  _applyTests();

  final words = [
    for (final t in ['如', '果', '你', '觉', '得', '有', '点', '贵', '那', '就'])
      VoiceWord(
          text: t,
          startMs: ['如', '果', '你', '觉', '得', '有', '点', '贵', '那', '就']
                  .indexOf(t) *
              300,
          endMs: (['如', '果', '你', '觉', '得', '有', '点', '贵', '那', '就']
                      .indexOf(t) +
                  1) *
              300),
  ];
  final vo = LineVoiceover(
    audioPath: '/v.mp3',
    durationMs: 3000,
    sourceText: '如果你觉得有点贵那就',
    voiceId: 'v',
    speechRate: 0,
    words: words,
  );

  LineShot bound(int s, int e) => LineShot(
      materialId: 100 + s, name: 'm$s', durationMs: 9999,
      startWord: s, endWord: e);

  ScriptDoc docWith(List<LineShot> shots) => ScriptDoc([
        ScriptLine.create(text: vo.sourceText)
            .withVoiceover(vo)
            .withShots(shots),
      ]);

  RenewTask taskOf(ScriptDoc doc) => RenewTask(
        id: 't1',
        name: '片子',
        sourcePath: null,
        status: RenewTaskStatus.ready,
        createdAt: DateTime.utc(2026, 8, 27),
        updatedAt: DateTime.utc(2026, 8, 27),
        units: const [],
        script: doc,
      );

  group('读：镜头绑了哪几个字', () {
    test('划词镜给出词区间和它绑的那段文字', () {
      final json = scriptTaskJson(taskOf(docWith([bound(0, 8)])));
      final shot = ((json['lines'] as List).first as Map)['shots'] as List;
      final s = shot.first as Map;
      expect(s['startWord'], 0);
      expect(s['endWord'], 8);
      expect(s['boundText'], '如果你觉得有点贵',
          reason: '给出文字，Agent 才不用自己去拼词');
    });

    test('自由镜没有这几项——不能让 Agent 以为它绑了字', () {
      const free = LineShot(materialId: 9, name: '自由', durationMs: 999);
      final json = scriptTaskJson(taskOf(docWith([free])));
      final s = (((json['lines'] as List).first as Map)['shots'] as List).first
          as Map;
      expect(s.containsKey('startWord'), isFalse);
    });
  });

  group('读：哪些字还能划', () {
    test('行里给出逐字时间，Agent 才算得出一段读多久', () {
      final json = scriptLineJson(docWith(const []), 0);
      final w = json['words'] as List;
      expect(w, hasLength(10));
      expect((w.first as Map)['text'], '如');
      expect((w.first as Map)['startMs'], 0);
    });

    test('已经被占住的字要标出来——Agent 不该提交一个必然被拒的区间', () {
      final json = scriptLineJson(docWith([bound(0, 5)]), 0);
      final taken = json['takenWords'] as List;
      expect(taken, hasLength(1));
      expect((taken.first as Map)['start'], 0);
      expect((taken.first as Map)['end'], 5);
    });

    test('没有配音时说清划不了', () {
      final doc = ScriptDoc([ScriptLine.create(text: '还没配音')]);
      final json = scriptLineJson(doc, 0);
      expect(json['canPickWords'], isFalse);
    });
  });

  group('写：提交一个词区间', () {
    test('合法区间通过', () {
      final doc = docWith(const []);
      expect(
          validateWordShotSubmission(doc: doc, picks: const [
            (lineIndex: 0, startWord: 0, endWord: 5, materialId: 7)
          ], offered: const {7}),
          isEmpty);
    });

    test('和已有划词镜重叠：拒绝，并说清该先删哪一镜', () {
      final doc = docWith([bound(0, 5)]);
      final issues = validateWordShotSubmission(doc: doc, picks: const [
        (lineIndex: 0, startWord: 3, endWord: 8, materialId: 7)
      ], offered: const {7});
      expect(issues, hasLength(1));
      expect(issues.single.message, contains('重叠'));
    });

    test('词区间超出这一句的字数：拒绝', () {
      final doc = docWith(const []);
      expect(
          validateWordShotSubmission(doc: doc, picks: const [
            (lineIndex: 0, startWord: 5, endWord: 99, materialId: 7)
          ], offered: const {7}),
          hasLength(1));
    });

    test('起点不小于终点：拒绝', () {
      final doc = docWith(const []);
      expect(
          validateWordShotSubmission(doc: doc, picks: const [
            (lineIndex: 0, startWord: 5, endWord: 5, materialId: 7)
          ], offered: const {7}),
          hasLength(1));
    });

    test('素材不在候选里：拒绝——不许凭空造 id', () {
      final doc = docWith(const []);
      expect(
          validateWordShotSubmission(doc: doc, picks: const [
            (lineIndex: 0, startWord: 0, endWord: 5, materialId: 999)
          ], offered: const {7}),
          hasLength(1));
    });

    test('这一行还没配音：拒绝，因为算不出时长', () {
      final doc = ScriptDoc([ScriptLine.create(text: '还没配音')]);
      final issues = validateWordShotSubmission(doc: doc, picks: const [
        (lineIndex: 0, startWord: 0, endWord: 2, materialId: 7)
      ], offered: const {7});
      expect(issues, hasLength(1));
      expect(issues.single.message, contains('配音'));
    });

    test('同一批里两个区间互相重叠也要拒', () {
      final doc = docWith(const []);
      expect(
          validateWordShotSubmission(doc: doc, picks: const [
            (lineIndex: 0, startWord: 0, endWord: 5, materialId: 7),
            (lineIndex: 0, startWord: 3, endWord: 8, materialId: 8),
          ], offered: const {7, 8}),
          isNotEmpty);
    });
  });
}

/// 提交之后：时长必须按**朗读长短**算，不是平摊。
/// 这是划词的全部意义——真机上因为走了老的均分，划的词被平摊掉过一次。
void _applyTests() {
  test('两段字数不同的划词镜，落盘后时长不同', () {
    final words = [
      for (var i = 0; i < 10; i++)
        VoiceWord(text: '字', startMs: i * 300, endMs: (i + 1) * 300),
    ];
    final line = ScriptLine.create(text: '字' * 10).withVoiceover(LineVoiceover(
      audioPath: '/v.mp3',
      durationMs: 3000,
      sourceText: '字' * 10,
      voiceId: 'v',
      speechRate: 0,
      words: words,
    ));
    var doc = ScriptDoc([line]);
    // 划 [0,3) 和 [3,9)：3 个字 vs 6 个字
    for (final p in const [(0, 3, 101), (3, 9, 102)]) {
      final l = doc.lines[0];
      final shot = LineShot(
          materialId: p.$3, name: 'm', durationMs: 99999,
          startWord: p.$1, endWord: p.$2);
      final shots = [...l.shots, shot];
      doc = doc.setShotsById(l.id, reallocShots(l, shots));
    }
    final a = doc.lines[0].shots[0].allocMs!;
    final b = doc.lines[0].shots[1].allocMs!;
    expect(a, isNot(b), reason: '3 个字和 6 个字读的时长不可能相等');
    expect(b, greaterThan(a));
  });
}
