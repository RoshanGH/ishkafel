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
