import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/script/reference_shots.dart';
import 'package:ishkafel/core/script/script_doc.dart';

/// 参考片的两层各自成立：
/// - 视觉镜头层的边界由**画面切点**决定，一个镜头就是一个完整镜头
/// - 台词层决定成片时间
/// 两者之间是**关联**（这一句对应哪几镜），不是**切割**。
///
/// 真机任务 hluyggdhpb 踩过的坑：老实现拿「台词区间 ∩ 切点」当参考镜，
/// 45 个参考镜里 19 个短于 1 秒、最短 3 毫秒——每句台词的开头都挂着
/// 上一个画面的尾巴。拿 3 毫秒碎片抽帧去打标/搜相似，搜出来的当然不是同类。
void main() {
  AsrSentence say(String text, int startMs, int endMs) =>
      AsrSentence(startMs: startMs, endMs: endMs, text: text);

  group('完整镜头序列（buildWholeShots）', () {
    test('切点把整条片子切满：首尾都在，不留缝', () {
      final shots =
          buildWholeShots(cuts: const [3000, 8000, 12000], durationMs: 20000);
      expect(shots, [(0, 3000), (3000, 8000), (8000, 12000), (12000, 20000)]);
    });

    test('碎镜并回相邻镜：闪一下的卡没有参考价值', () {
      final shots =
          buildWholeShots(cuts: const [200, 3000, 3100], durationMs: 9000);
      expect(shots, [(0, 3100), (3100, 9000)],
          reason: '3000~3100 的碎镜并回前一镜，开头 200ms 的碎镜再并入后一镜');
    });

    test('一个切点都没有 → 不硬造「整片一镜」，交给老算法', () {
      expect(buildWholeShots(cuts: const [], durationMs: 20000), isEmpty);
    });

    test('时长未知 → 空序列（末镜的终点无从谈起）', () {
      expect(buildWholeShots(cuts: const [3000], durationMs: 0), isEmpty);
    });

    test('越界切点被丢掉，不产生负长度镜头', () {
      final shots =
          buildWholeShots(cuts: const [-100, 0, 4000, 9000, 20000], durationMs: 9000);
      expect(shots, [(0, 4000), (4000, 9000)]);
    });
  });

  group('台词与完整镜头的关联（buildReferenceLines）', () {
    // 全片四镜：(0,3000) (3000,8000) (8000,12000) (12000,20000)
    const cuts = [3000, 8000, 12000];
    const durationMs = 20000;

    List<ScriptLine> build(List<AsrSentence> sentences) => buildReferenceLines(
          sentences: sentences,
          cuts: cuts,
          durationMs: durationMs,
        );

    test('一句台词落在镜头中间 → 参考镜是完整镜头，不被台词边界切碎', () {
      final lines = build([say('第一句', 500, 2500)]);
      final ref = lines
          .firstWhere((l) => l.type == ScriptLineType.voiced)
          .reference!;
      expect(ref.segments, [(0, 3000)],
          reason: '台词只占 500~2500，但这一镜的真实边界是 0~3000');
      expect(ref.startMs, 500, reason: '台词层的时间不变');
      expect(ref.endMs, 2500);
    });

    test('一句跨两镜 → 两镜都完整，不出 3 毫秒碎片', () {
      final lines = build([say('跨镜的一句', 3200, 9500)]);
      final ref = lines
          .firstWhere((l) => l.type == ScriptLineType.voiced)
          .reference!;
      expect(ref.segments, [(3000, 8000), (8000, 12000)]);
      expect(ref.segments.every((s) => s.$2 - s.$1 >= 1000), isTrue,
          reason: '没有短于 1 秒的碎镜');
    });

    test('台词开头压着上一镜 3 毫秒的尾巴 → 那一镜不算这一句的画面', () {
      final lines = build([say('压着尾巴的一句', 2997, 7000)]);
      final voiced = lines.firstWhere((l) => l.type == ScriptLineType.voiced);
      expect(voiced.reference!.segments, [(3000, 8000)],
          reason: '(0,3000) 那一镜只被压到 3 毫秒，是上一个画面的尾巴');
      expect(lines.first.reference!.segments, [(0, 3000)],
          reason: '甩掉的那一镜没人认领 → 成画面行，不会凭空消失');
    });

    test('一个镜头跨多句台词 → 几句都关联到它（镜头可共用）', () {
      final lines = build([
        say('前半句', 8200, 9500),
        say('后半句', 9800, 11500),
      ]);
      final voiced =
          lines.where((l) => l.type == ScriptLineType.voiced).toList();
      expect(voiced, hasLength(2));
      expect(voiced[0].reference!.segments, [(8000, 12000)]);
      expect(voiced[1].reference!.segments, [(8000, 12000)]);
    });

    test('没被任何台词覆盖的镜头 → 画面行（用 manualMs 定时长）', () {
      final lines = build([say('中间那句', 3200, 7500)]);
      expect(lines.map((l) => l.type), [
        ScriptLineType.visual,
        ScriptLineType.voiced,
        ScriptLineType.visual,
        ScriptLineType.visual,
      ], reason: '开头空镜、结尾定格都要成行，否则复刻出来的片子直接少掉这几段');
      expect(lines.first.text, isEmpty);
      expect(lines.first.manualMs, 3000);
      expect(lines.first.reference!.segments, [(0, 3000)]);
      expect(lines.last.manualMs, 8000);
      expect(lines.last.reference!.segments, [(12000, 20000)]);
    });

    test('行按时间排序：画面行插在它该在的位置', () {
      final lines = build([
        say('第一句', 500, 2500),
        say('第二句', 8200, 11500),
      ]);
      expect(lines.map((l) => l.text), ['第一句', '', '第二句', '']);
      expect(lines[1].reference!.segments, [(3000, 8000)]);
    });

    test('词级时间戳跟着台词走（找镜头面板要裁「这一镜说了哪几个字」）', () {
      final lines = buildReferenceLines(
        sentences: [
          AsrSentence(
            startMs: 3200,
            endMs: 5000,
            text: '家人们',
            words: const [
              AsrWord(text: '家', startMs: 3200, endMs: 3500),
              AsrWord(text: '人', startMs: 3500, endMs: 3800),
              AsrWord(text: '们', startMs: 3800, endMs: 4100),
            ],
          ),
        ],
        cuts: cuts,
        durationMs: durationMs,
      );
      final voiced = lines.firstWhere((l) => l.type == ScriptLineType.voiced);
      expect(voiced.reference!.words.map((w) => w.text).join(), '家人们');
    });

    test('空白台词不产配音行', () {
      final lines = build([say('   ', 3200, 7500)]);
      expect(lines.every((l) => l.type == ScriptLineType.visual), isTrue);
    });

    test('一个切点都没有（场景检测没出结果）→ 退回老算法：一句一镜、按台词边界', () {
      final lines = buildReferenceLines(
        sentences: [say('第一句', 500, 2500)],
        cuts: const [],
        durationMs: 20000,
      );
      expect(lines, hasLength(1), reason: '没有镜头层就不该凭空造画面行');
      final ref = lines.first.reference!;
      expect(ref.hasWholeShots, isFalse);
      expect(ref.segments, [(500, 2500)]);
    });
  });
}
