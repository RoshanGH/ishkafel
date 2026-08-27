import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/script/shot_allocation.dart';

/// 划词建镜：**选中几个字，那一镜就是这几个字的朗读时长**。
///
/// 此前字幕记「第几个字」、镜头记「多少毫秒」，两套坐标系没法对齐——
/// 人要让画面对上某几个字，只能自己听、自己算秒数、手动填。
///
/// 划词镜记的是**词区间**，时长现算：换音色、重配音之后朗读长短全变，
/// 切点不变，时长自动跟上。
void main() {
  /// 8 秒一句，10 个词，每词 800ms
  final words = [
    for (var i = 0; i < 10; i++)
      VoiceWord(text: '字$i', startMs: i * 800, endMs: (i + 1) * 800),
  ];

  LineShot bound(int start, int end, {int durationMs = 99999}) => LineShot(
      materialId: start + 1,
      name: 'm$start',
      durationMs: durationMs,
      startWord: start,
      endWord: end);

  const free = LineShot(materialId: 99, name: '自由', durationMs: 99999);

  group('划词镜的时长由词区间算出来', () {
    test('头两个词 = 1600ms', () {
      expect(wordSpanMs(words, 0, 2), 1600);
    });

    test('中间几个词', () {
      expect(wordSpanMs(words, 3, 6), 2400);
    });

    test('越界的区间夹回来，不返回负数或抛错', () {
      expect(wordSpanMs(words, 8, 99), 1600);
      expect(wordSpanMs(words, -5, 2), 1600);
      expect(wordSpanMs(words, 5, 5), 0);
    });

    test('没有逐字时间就算不出来——返回 null 而不是猜一个', () {
      expect(wordSpanMs(const [], 0, 2), isNull);
    });

    /// 真机数据：「贵」收音 1440ms，下一个字「那」开口 1560ms，
    /// 中间 120ms 是逗号的气口。这一段必须归前一镜，否则画面会在停顿
    /// 刚开始时就切走，急了小半拍
    group('标点的气口归前一镜', () {
      final withGap = [
        VoiceWord(text: '贵', startMs: 1160, endMs: 1440),
        VoiceWord(text: '那', startMs: 1560, endMs: 1760), // 中间空 120ms
      ];

      test('算到下一个字开口，不是算到本字收音', () {
        expect(wordSpanMs(withGap, 0, 1), 1560 - 1160,
            reason: '气口归前一镜——按收音切会早切 120ms');
      });

      test('最后一段收到配音结尾：句尾余韵也归它', () {
        expect(wordSpanMs(withGap, 1, 2, totalMs: 2100), 2100 - 1560,
            reason: 'TTS 尾部稳定有 200~350ms 静音，不给它整句就短一截');
      });

      test('没给总长时最后一段退回本字收音，不瞎猜', () {
        expect(wordSpanMs(withGap, 1, 2), 1760 - 1560);
      });

      test('整句划成两段，加起来正好等于配音总长', () {
        final a = wordSpanMs(withGap, 0, 1)!;
        final b = wordSpanMs(withGap, 1, 2, totalMs: 2100)!;
        expect(a + b, 2100 - 1160,
            reason: '段与段首尾相接，中间不漏一帧');
      });
    });
  });

  group('混合分配：划词镜定死，自由镜分剩下的', () {
    test('划头 2 词、划尾 2 词，中间 1 个自由镜吃掉剩下的', () {
      final shots = [bound(0, 2), free, bound(8, 10)];
      final r = ShotAllocation.distributeWithWords(shots, 8000, words);
      expect(r[0].allocMs, 1600);
      expect(r[2].allocMs, 1600);
      expect(r[1].allocMs, 8000 - 1600 - 1600, reason: '中间那段是硬约束');
    });

    test('中间放几个镜头都行，加起来还是那么多', () {
      final shots = [bound(0, 2), free, free, free, bound(8, 10)];
      final r = ShotAllocation.distributeWithWords(shots, 8000, words);
      final middle = r[1].allocMs! + r[2].allocMs! + r[3].allocMs!;
      expect(middle, 4800);
      expect(r.fold<int>(0, (a, s) => a + s.allocMs!), 8000);
    });

    test('全是划词镜、中间留了空隙：不去凑满，如实少一段', () {
      // 词 2~8 没有任何镜头覆盖 → 这一行铺不满，由现有的分配不足检测拦住
      final shots = [bound(0, 2), bound(8, 10)];
      final r = ShotAllocation.distributeWithWords(shots, 8000, words);
      expect(r.fold<int>(0, (a, s) => a + s.allocMs!), 3200);
      expect(ShotAllocation.shortfallMs(r, 8000), 4800,
          reason: '缺口要如实报出来，不能悄悄把画面拉长顶上');
    });

    test('一个划词镜都没有：退回原来的均分', () {
      final r = ShotAllocation.distributeWithWords(
          [free, free], 8000, words);
      expect(r[0].allocMs, 4000);
      expect(r[1].allocMs, 4000);
    });

    test('没有逐字时间：划词镜也只能按均分处理，不能算出个假时长', () {
      final r = ShotAllocation.distributeWithWords(
          [bound(0, 2), free], 8000, const []);
      expect(r[0].allocMs! + r[1].allocMs!, 8000);
    });

    test('划词镜把整句占满了：自由镜分到 0，也要如实说', () {
      final shots = [bound(0, 10), free];
      final r = ShotAllocation.distributeWithWords(shots, 8000, words);
      expect(r[0].allocMs, 8000);
      expect(r[1].allocMs, 0, reason: '不能倒扣划词镜去凑给自由镜');
    });

    test('素材不够长的划词镜：如实给出它能给的，缺口另算', () {
      // 那一镜只有 1 秒素材，却要占 1.6 秒
      final shots = [bound(0, 2, durationMs: 1000), free];
      final r = ShotAllocation.distributeWithWords(shots, 8000, words);
      expect(r[0].allocMs, lessThanOrEqualTo(1600));
    });
  });

  group('重叠与越界要认得出来', () {
    test('两个划词镜重叠', () {
      expect(wordBoundConflict([bound(0, 5), bound(3, 8)]), isNotNull);
    });

    test('首尾相接不算重叠', () {
      expect(wordBoundConflict([bound(0, 5), bound(5, 8)]), isNull);
    });

    test('顺序颠倒也算冲突——划词镜必须按词序排', () {
      expect(wordBoundConflict([bound(5, 8), bound(0, 3)]), isNotNull);
    });

    test('自由镜不参与判定', () {
      expect(wordBoundConflict([bound(0, 3), free, bound(5, 8)]), isNull);
    });
  });
}
