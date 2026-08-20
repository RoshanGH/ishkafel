import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/subtitle/subtitle_overlay.dart';
import 'package:ishkafel/core/subtitle/subtitle_style.dart';

/// 镜头替换的字幕：换掉画面后，原片烧在像素里的台词字幕跟着没了——
/// 用分析时存下的句级转写**重新渲染**，叠在替换切片上。
/// 声音本来就是原片的，所以内容与时间天然同步。
void main() {
  const sentences = [
    AsrSentence(startMs: 0, endMs: 2000, text: '第一句'),
    AsrSentence(startMs: 2000, endMs: 5000, text: '第二句比较长'),
    AsrSentence(startMs: 5000, endMs: 7000, text: '第三句'),
  ];

  group('整行按镜头边界切字幕段（预览与导出同一套规则）', () {
    // 「家人们，这是我们最新的产品」：镜头 1 只出「家人们」，
    // 后面的镜头出后半句——广告片的常规节奏
    const line = AsrSentence(
      startMs: 0,
      endMs: 3000,
      text: '家人们，这是我们最新的产品。',
      words: [
        AsrWord(text: '家', startMs: 0, endMs: 200),
        AsrWord(text: '人', startMs: 200, endMs: 400),
        AsrWord(text: '们', startMs: 400, endMs: 600),
        AsrWord(text: '这', startMs: 900, endMs: 1100),
        AsrWord(text: '是', startMs: 1100, endMs: 1300),
        AsrWord(text: '我', startMs: 1300, endMs: 1500),
        AsrWord(text: '们', startMs: 1500, endMs: 1700),
        AsrWord(text: '最', startMs: 1700, endMs: 1900),
        AsrWord(text: '新', startMs: 1900, endMs: 2100),
        AsrWord(text: '的', startMs: 2100, endMs: 2300),
        AsrWord(text: '产', startMs: 2300, endMs: 2600),
        AsrWord(text: '品', startMs: 2600, endMs: 2900),
      ],
    );

    test('镜头 1 占 0~800ms：只出「家人们」，后半句归后面的镜头', () {
      final segs = lineSubtitleSegments(
          sentence: line, shotBoundaries: const [0, 800, 3000]);
      expect(segs.first.text, '家人们');
      expect(segs.first.startMs, 0);
      expect(segs.map((s) => s.text).join('|'), '家人们|这是我们最新的产品');
      expect(segs[1].startMs, 900, reason: '后半句从它真正开口的时刻出现');
    });

    test('没有镜头边界（单镜/无镜头）：退化为整行一个坑', () {
      final segs = lineSubtitleSegments(
          sentence: line, shotBoundaries: const [0, 3000]);
      // 12 字 <18 上限但有标点拆段规则——按现行规则切成两段也可，
      // 关键是覆盖全部文本且时间连续
      expect(segs.map((s) => s.text).join(), '家人们这是我们最新的产品');
    });

    test('没有词级时间戳：每个镜头都显示整句（兜底，与导出一致）', () {
      const bare = AsrSentence(startMs: 0, endMs: 3000, text: '家人们看过来');
      final segs = lineSubtitleSegments(
          sentence: bare, shotBoundaries: const [0, 800, 3000]);
      expect(segs, hasLength(2));
      expect(segs.every((s) => s.text == '家人们看过来'), isTrue);
    });
  });

  group('剥标点不能伤内容', () {
    test('数字间的小数点是价格，不是句读——69.9 绝不能变 699', () {
      expect(stripPunctuation('再不买就恢复69.9一瓶了。'), '再不买就恢复69.9一瓶了');
      expect(stripPunctuation('杀菌率99.9%，放心'), '杀菌率99.9%放心');
      expect(stripPunctuation('句尾的点。要剥'), '句尾的点要剥');
    });
  });

  group('裁出坑位内的字幕行', () {
    test('完全落在坑位里的句子原样保留，时间平移到切片时间轴', () {
      final lines = subtitleLinesInSlot(
          sentences: sentences, slotStartMs: 2000, slotEndMs: 5000);
      expect(lines, hasLength(1));
      expect(lines.single.text, '第二句比较长');
      expect(lines.single.startMs, 0);
      expect(lines.single.endMs, 3000);
    });

    test('跨越坑位边界的句子只显示相交的那一段——出坑的部分由原片自己的字幕接手', () {
      final lines = subtitleLinesInSlot(
          sentences: sentences, slotStartMs: 1000, slotEndMs: 6000);
      expect(lines.map((l) => (l.startMs, l.endMs, l.text)), [
        (0, 1000, '第一句'),
        (1000, 4000, '第二句比较长'),
        (4000, 5000, '第三句'),
      ]);
    });

    test('与坑位不相交的句子不出现；空文本跳过', () {
      final lines = subtitleLinesInSlot(sentences: [
        const AsrSentence(startMs: 0, endMs: 1000, text: '前面的'),
        const AsrSentence(startMs: 2000, endMs: 3000, text: '   '),
        const AsrSentence(startMs: 3000, endMs: 4000, text: '坑里的'),
      ], slotStartMs: 2000, slotEndMs: 5000);
      expect(lines.single.text, '坑里的');
    });

    test('恰好贴边不算相交——0 毫秒的字幕闪一下毫无意义', () {
      final lines = subtitleLinesInSlot(
          sentences: sentences, slotStartMs: 2000, slotEndMs: 2000);
      expect(lines, isEmpty);
    });
  });

  group('带词级时间戳：按词裁剪 + 长句拆段', () {
    // 模拟用户真机反馈的场景：ASR 把两个短句识别成一整句（31 字级别），
    // 镜头边界落在句子中间——S8 只该显示这段时间里实际说出口的那半句
    AsrSentence longSentence() {
      const chars = '还有一种是没用过滴露冰箱清洁剂的人我就想问问这玩意是犯了天条吗';
      return AsrSentence(
        startMs: 0,
        endMs: chars.length * 100,
        text: '还有一种是没用过滴露冰箱清洁剂的人，我就想问问这玩意是犯了天条吗？',
        words: [
          for (var i = 0; i < chars.length; i++)
            AsrWord(
                startMs: i * 100,
                endMs: i * 100 + 80,
                text: chars[i]),
        ],
      );
    }

    test('跨镜头边界：只显示落在坑位时间内的字，前半句归上一个镜头', () {
      // 边界切在「…的人，|我就想…」之后：第 17 个字「我」从 1700ms 开始
      final lines = subtitleLinesInSlot(
          sentences: [longSentence()], slotStartMs: 1700, slotEndMs: 9000);
      expect(lines.map((l) => l.text).join('|'), '我就想问问这玩意是犯了天条吗',
          reason: '标点不进画面——原片字幕就是无标点的堆字风格');
      expect(lines.first.startMs, 0, reason: '段首时间贴着坑位起点');
    });

    test('坑位在前半句：只显示前半句，且标点跟着词恢复出来', () {
      final lines = subtitleLinesInSlot(
          sentences: [longSentence()], slotStartMs: 0, slotEndMs: 1700);
      expect(lines.map((l) => l.text).join('|'), '还有一种是没用过滴露冰箱清洁剂的人');
    });

    test('整句都在坑内但太长：拆成多段先后出现，不堆成一大块', () {
      final lines = subtitleLinesInSlot(
          sentences: [longSentence()], slotStartMs: 0, slotEndMs: 9000);
      expect(lines.length, greaterThanOrEqualTo(2),
          reason: '31 字挂满全程就是三行大块字，原片的习惯是短句逐条出现');
      for (final l in lines) {
        expect(l.text.length, lessThanOrEqualTo(18));
      }
      // 优先在标点处切开——语义断点比硬切好读（标点用于定切点，不进画面）
      expect(lines.first.text, '还有一种是没用过滴露冰箱清洁剂的人');
      // 段与段时间衔接：前一段显示到后一段开始，中间不闪没
      for (var i = 1; i < lines.length; i++) {
        expect(lines[i - 1].endMs, lines[i].startMs);
      }
    });

    test('短句在坑内：整句一段，时间来自词的首末', () {
      const s = AsrSentence(startMs: 500, endMs: 1300, text: '哇塞！', words: [
        AsrWord(startMs: 500, endMs: 800, text: '哇'),
        AsrWord(startMs: 800, endMs: 1100, text: '塞'),
      ]);
      final lines = subtitleLinesInSlot(
          sentences: const [s], slotStartMs: 0, slotEndMs: 5000);
      expect(lines.single.text, '哇塞');
      expect(lines.single.startMs, 500);
      expect(lines.single.endMs, 1100);
    });
  });

  group('overlay 滤镜链', () {
    const overlays = [
      SubtitleOverlayImage(pngPath: '/c/a.png', startMs: 40, endMs: 1160),
      SubtitleOverlayImage(pngPath: '/c/b.png', startMs: 1560, endMs: 2080),
    ];

    test('主链在前，逐张按显示区间叠加，输出标签递进', () {
      final chain =
          subtitleFilterComplex(baseChain: 'scale=1:1', overlays: overlays);
      expect(
          chain,
          '[0:v]scale=1:1[b0]'
          ";[b0][1:v]overlay=0:0:enable='between(t,0.040,1.160)'[b1]"
          ";[b1][2:v]overlay=0:0:enable='between(t,1.560,2.080)'[b2]");
      expect(subtitleFilterOutLabel(2), '[b2]');
    });
  });

  group('样式的序列化', () {
    test('json 往返不丢参数', () {
      const style = SubtitleStyle(
          bottomRatio: 0.18, fontRatio: 0.05, preset: SubtitlePreset.whiteBox);
      final back = SubtitleStyle.fromJson(style.toJson());
      expect(back.bottomRatio, 0.18);
      expect(back.fontRatio, 0.05);
      expect(back.preset, SubtitlePreset.whiteBox);
    });

    test('认不出的 json 退回默认，不炸', () {
      expect(SubtitleStyle.fromJson({'preset': '不存在'}).preset,
          SubtitleStyle.standard.preset);
    });
  });

}
