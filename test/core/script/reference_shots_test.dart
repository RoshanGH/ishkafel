import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/analysis/segmentation_builder.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/script/reference_shots.dart';
import 'package:ishkafel/core/script/script_doc.dart';

/// 参考片的切分**必须和替换裂变一模一样**：分子（台词语义单元）就是一行，
/// 原子（视觉镜头）就是这一行点进去看到的那几个参考分镜。
///
/// 产品负责人的原话：「你那边怎么切分子，这边就是怎么切行。原子就是我点参考
/// 进去以后的那几个分镜。」此前这里另写了一套「一句一行 + 事后关联镜头跨度」，
/// 结果一个完整镜头横跨三行——同一个画面被切成 0.6/0.4/1.6 三张卡。
void main() {
  SemanticUnit unit(int start, int end, String text, List<int> innerCuts) {
    final edges = [start, ...innerCuts, end];
    return SemanticUnit(
      index: 0,
      startMs: start,
      endMs: end,
      transcript: text,
      shots: [
        for (var i = 0; i < edges.length - 1; i++)
          Shot(startMs: edges[i], endMs: edges[i + 1]),
      ],
    );
  }

  group('分子 → 行，原子 → 行内的参考分镜', () {
    test('一个单元一行，行内的分镜就是这个单元内部的那几镜', () {
      final lines = linesFromUnits(
        units: [unit(0, 7000, '看到没有？活的。天呐，这也太夸张了吧！', [2900])],
        sentences: const [],
      );
      expect(lines, hasLength(1), reason: '三句短台词在同一个语义单元里，就是一行');
      expect(lines.first.reference!.segments, [(0, 2900), (2900, 7000)],
          reason: '行内两个原子——点参考进去应该看到两个分镜');
    });

    test('原子一定落在分子里，不会横跨两行', () {
      final lines = linesFromUnits(
        units: [
          unit(0, 5000, '第一段', [2000]),
          unit(5000, 9000, '第二段', []),
        ],
        sentences: const [],
      );
      for (final l in lines) {
        final ref = l.reference!;
        for (final (s, e) in ref.segments) {
          expect(s, greaterThanOrEqualTo(ref.startMs));
          expect(e, lessThanOrEqualTo(ref.endMs));
        }
      }
    });

    test('没有台词的单元成画面行，时长手填——它没有配音，不填在成片里就是 0', () {
      final lines = linesFromUnits(
        units: [unit(0, 2900, '', [])],
        sentences: const [],
      );
      expect(lines.single.type, ScriptLineType.visual);
      expect(lines.single.manualMs, 2900);
    });

    test('词级时间戳按中点归属，边界上的词不会同时算进两行', () {
      final sentences = [
        AsrSentence(startMs: 0, endMs: 2000, text: '你好世界', words: const [
          AsrWord(text: '你好', startMs: 0, endMs: 900),
          AsrWord(text: '世界', startMs: 1100, endMs: 2000),
        ]),
      ];
      final lines = linesFromUnits(
        units: [unit(0, 1000, '你好', []), unit(1000, 2000, '世界', [])],
        sentences: sentences,
      );
      expect(lines[0].reference!.words.map((w) => w.text), ['你好']);
      expect(lines[1].reference!.words.map((w) => w.text), ['世界']);
    });
  });

  group('没有台词的长段落要能成行——不然复刻出来的片子少一截', () {
    test('开头的吸睛段补成一个空台词草稿', () {
      final out = draftsWithVisualGaps(
        drafts: [const UnitDraft(startMs: 2900, endMs: 7000, transcript: '有台词')],
        durationMs: 9000,
      );
      expect(out.first.startMs, 0);
      expect(out.first.endMs, 2900);
      expect(out.first.transcript, isEmpty);
      expect(out.last.startMs, 7000, reason: '结尾 2 秒无口播也要成段');
    });

    test('闪一下的空隙不单独成行，交给边界吸附并进去', () {
      final out = draftsWithVisualGaps(
        drafts: [
          const UnitDraft(startMs: 100, endMs: 3000, transcript: 'a'),
          const UnitDraft(startMs: 3200, endMs: 6000, transcript: 'b'),
        ],
        durationMs: 6000,
      );
      expect(out, hasLength(2), reason: '开头 100ms、中间 200ms 都不够成一个段落');
    });
  });
}
