import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/script/script_doc.dart';

/// 脚本成片的数据根：脚本行。
///
/// 「脚本即成片」——行是唯一概念：配音行（有台词，配音时长是根）与
/// 画面行（空文案，手填时长或随素材）。见 docs/2026-08-19 设计稿。
void main() {
  group('行类型由文案判定', () {
    test('有文案 = 配音行', () {
      expect(ScriptLine.create(text: '世界上只有两种人').type,
          ScriptLineType.voiced);
    });

    test('空文案 = 画面行（空行也是结构的一部分）', () {
      expect(ScriptLine.create(text: '').type, ScriptLineType.visual);
      expect(ScriptLine.create(text: '   ').type, ScriptLineType.visual);
    });

    test('改文案后类型跟着变——画面行填上字就是配音行', () {
      final line = ScriptLine.create(text: '');
      final voiced = line.withText('新台词');
      expect(voiced.type, ScriptLineType.voiced);
      expect(voiced.id, line.id, reason: '行的身份不因内容变化而变');
    });
  });

  group('文档操作（全部不可变）', () {
    test('新建脚本自带一个空行——编导打开就能写，不用先学会「加行」', () {
      final doc = ScriptDoc.empty();
      expect(doc.lines, hasLength(1));
      expect(doc.lines.single.type, ScriptLineType.visual);
    });

    test('插入新行在指定行之后', () {
      final doc = ScriptDoc.empty().insertAfter(0, text: '第一句');
      expect(doc.lines, hasLength(2));
      expect(doc.lines[1].text, '第一句');
    });

    test('删除行；最后一行不许删——脚本至少有一行可写', () {
      final doc = ScriptDoc.empty().insertAfter(0, text: 'A');
      final removed = doc.removeAt(0);
      expect(removed.lines.single.text, 'A');
      expect(removed.removeAt(0).lines, hasLength(1),
          reason: '删到只剩一行就不再删');
    });

    test('移动行（拖动排序）', () {
      var doc = ScriptDoc.empty();
      doc = doc.insertAfter(0, text: 'A').insertAfter(1, text: 'B');
      final moved = doc.move(2, 0);
      expect(moved.lines.map((l) => l.text).toList(), ['B', '', 'A']);
    });

    test('改某行文案', () {
      final doc = ScriptDoc.empty().updateText(0, '填上了');
      expect(doc.lines.single.text, '填上了');
      expect(doc.lines.single.type, ScriptLineType.voiced);
    });

    test('画面行手填时长；配音行不存手填时长（配音时长才是根）', () {
      final doc = ScriptDoc.empty().setManualMs(0, 4000);
      expect(doc.lines.single.manualMs, 4000);
    });
  });

  group('参考原子（LineRef）', () {
    test('词级时间戳 json 往返；原子文本按词中点归属裁出', () {
      final ref = LineRef(
        startMs: 1000,
        endMs: 4000,
        cuts: const [2000],
        words: const [
          VoiceWord(text: '家', startMs: 1000, endMs: 1300),
          VoiceWord(text: '人', startMs: 1300, endMs: 1600),
          VoiceWord(text: '们', startMs: 1600, endMs: 1900),
          VoiceWord(text: '看', startMs: 2200, endMs: 2500),
          VoiceWord(text: '这', startMs: 2500, endMs: 2800),
        ],
      );
      final back = LineRef.tryFromJson(ref.toJson())!;
      expect(back.words.length, 5, reason: '词级时间戳随 json 往返');
      expect(back.segmentText(0, '整句'), '家人们',
          reason: '第一个原子（1000~2000）只说了「家人们」');
      expect(back.segmentText(1, '整句'), '看这');
    });

    test('老档没有词级数据：原子文本退回整句', () {
      final ref = LineRef(startMs: 0, endMs: 3000, cuts: const [1500]);
      expect(ref.segmentText(0, '整句台词'), '整句台词');
    });
  });

  group('镜头级字幕（字幕写在镜头上）', () {
    ScriptLine lineWith(List<LineShot> shots, {List<VoiceWord>? words}) {
      var l = ScriptLine.create(text: '家人们这是我们的最新产品')
          .withShots(shots)
          .withVoiceover(LineVoiceover(
            audioPath: '/vo.mp3',
            durationMs: 5000,
            sourceText: '家人们这是我们的最新产品',
            voiceId: 'v',
            speechRate: 0,
            words: words ??
                [
                  for (var i = 0; i < 12; i++)
                    VoiceWord(
                        text: '家人们这是我们的最新产品'[i],
                        startMs: i * 400,
                        endMs: i * 400 + 380),
                ],
          ));
      return l;
    }

    test('默认自动预填：每镜的字幕 = 这镜时段内说出口的字', () {
      final line = lineWith(const [
        LineShot(materialId: 1, name: 'a', durationMs: 9000, allocMs: 1200),
        LineShot(materialId: 2, name: 'b', durationMs: 9000, allocMs: 3800),
      ]);
      final segs = line.shotSubtitleSegments;
      expect(segs, hasLength(2));
      expect(segs[0].text, '家人们');
      expect(segs[0].startMs, 0);
      expect(segs[0].endMs, 1200);
      expect(segs[1].text, '这是我们的最新产品');
    });

    test('人写的字幕优先；相邻镜头同文本合并成一条连续段（不闪断）', () {
      final line = lineWith(const [
        LineShot(
            materialId: 1,
            name: 'a',
            durationMs: 9000,
            allocMs: 1700,
            subtitleText: '那就趁现在赶紧买'),
        LineShot(
            materialId: 2,
            name: 'b',
            durationMs: 9000,
            allocMs: 1400,
            subtitleText: '那就趁现在赶紧买'),
        LineShot(
            materialId: 3,
            name: 'c',
            durationMs: 9000,
            allocMs: 1900,
            subtitleText: '那就趁现在赶紧买'),
      ]);
      final segs = line.shotSubtitleSegments;
      expect(segs, hasLength(1), reason: '三镜同句 = 一条连续字幕');
      expect(segs.single.text, '那就趁现在赶紧买');
      expect(segs.single.startMs, 0);
      expect(segs.single.endMs, 5000);
    });

    test('长镜头的字幕按语言节奏分屏依次出现，不堆在画面上', () {
      // 一个镜头覆盖整句 12 个字（每字 400ms）：自动按标点/停顿/字数
      // 上限切成若干屏，一屏一屏出——原片里长镜头下字幕就是这么走的
      const long = '家人们你好呀，这是我们今年最新的爆款产品啊，真的很好用哦';
      final line = ScriptLine.create(text: long)
          .withShots(const [
            LineShot(
                materialId: 1, name: 'a', durationMs: 30000, allocMs: 7000),
          ])
          .withVoiceover(LineVoiceover(
            audioPath: '/vo.mp3',
            durationMs: 7000,
            sourceText: long,
            voiceId: 'v',
            speechRate: 0,
            words: [
              for (var i = 0; i < long.length; i++)
                VoiceWord(
                    text: long[i],
                    startMs: (i * 7000 / long.length).round(),
                    endMs: (i * 7000 / long.length).round() + 180),
            ],
          ));
      final segs = line.shotSubtitleSegments;
      expect(segs.length, greaterThan(1),
          reason: '一个长镜头下字幕该分屏依次出现，而不是一次堆上去');
      expect(segs.map((s) => s.text).join(),
          long.replaceAll(RegExp('[，。]'), ''),
          reason: '分屏只是分，字不能丢');
      for (final s in segs) {
        expect(s.endMs, greaterThan(s.startMs));
      }
      expect(segs.first.startMs, lessThan(segs[1].startMs),
          reason: '按说话顺序依次出现');
    });

    test('手写多行 = 一行一屏（人切的优先），时间按每屏第一个字说出口的时刻',
        () {
      final line = ScriptLine.create(text: '家人们你好呀这是我们的最新产品啊')
          .withShots(const [
            LineShot(
                materialId: 1,
                name: 'a',
                durationMs: 30000,
                allocMs: 7000,
                // 三行 = 三屏，按用户自己的句读切
                subtitleText: '家人们\n你好呀\n这是我们的最新产品啊'),
          ])
          .withVoiceover(LineVoiceover(
            audioPath: '/vo.mp3',
            durationMs: 7000,
            sourceText: '家人们你好呀这是我们的最新产品啊',
            voiceId: 'v',
            speechRate: 0,
            words: [
              for (var i = 0; i < 16; i++)
                VoiceWord(
                    text: '家人们你好呀这是我们的最新产品啊'[i],
                    startMs: i * 420,
                    endMs: i * 420 + 400),
            ],
          ));
      final segs = line.shotSubtitleSegments;
      expect(segs.map((s) => s.text).toList(),
          ['家人们', '你好呀', '这是我们的最新产品啊']);
      expect(segs[0].startMs, 0, reason: '第一屏从镜头开头就在');
      expect(segs[1].startMs, 3 * 420,
          reason: '第二屏从「你」说出口的那一刻出现');
      expect(segs[2].startMs, 6 * 420);
      expect(segs.last.endMs, 7000, reason: '最后一屏留到镜头结束');
    });

    test('对不回词序列时按字数比例分时间——不静默糊弄', () {
      final line = ScriptLine.create(text: '家人们你好')
          .withShots(const [
            LineShot(
                materialId: 1,
                name: 'a',
                durationMs: 9000,
                allocMs: 4000,
                subtitleText: '完全改过的词\n又一屏'),
          ])
          .withVoiceover(LineVoiceover(
            audioPath: '/vo.mp3',
            durationMs: 4000,
            sourceText: '家人们你好',
            voiceId: 'v',
            speechRate: 0,
            words: const [
              VoiceWord(text: '家', startMs: 0, endMs: 400),
              VoiceWord(text: '人', startMs: 400, endMs: 800),
            ],
          ));
      final segs = line.shotSubtitleSegments;
      expect(segs, hasLength(2));
      expect(segs[0].startMs, 0);
      expect(segs[1].endMs, 4000);
      expect(segs[1].startMs, greaterThan(0));
    });

    test('subtitleText json 往返；清空回到自动匹配', () {
      const shot = LineShot(
          materialId: 1,
          name: 'a',
          durationMs: 9000,
          allocMs: 1000,
          subtitleText: '家人们');
      expect(LineShot.tryFromJson(shot.toJson())!.subtitleText, '家人们');
      // 清空 = subtitleText 回到 null = 重新跟随自动匹配
      final line = lineWith(const [
        LineShot(materialId: 1, name: 'a', durationMs: 9000, allocMs: 5000),
      ]);
      expect(line.shotSubtitleSegments.single.text, '家人们这是我们的最新产品',
          reason: '没有手改就按词时间戳自动算这一镜的字');
    });
  });

  group('台词语义单元内的小行切分（sublineCuts）', () {
    // 「家人们，这是我们的最新产品」3 镜：「家人们」给前 2 镜、
    // 后半句给第 3 镜——用户定的分组模型
    ScriptLine line3shots() =>
        ScriptLine.create(text: '家人们，这是我们的最新产品').withShots(const [
          LineShot(materialId: 1, name: 'a', durationMs: 4000, allocMs: 2000),
          LineShot(materialId: 2, name: 'b', durationMs: 4000, allocMs: 1000),
          LineShot(materialId: 3, name: 'c', durationMs: 4000, allocMs: 2000),
        ]);

    test('设切点后 sublines 给出各小行的文本段与镜头范围', () {
      final line = line3shots().withSublineCuts(const [(4, 2)]);
      final subs = line.sublines;
      expect(subs, hasLength(2));
      expect(subs[0].text, '家人们，');
      expect(subs[0].shotStart, 0);
      expect(subs[0].shotEnd, 2, reason: '「家人们」占前两镜');
      expect(subs[1].text, '这是我们的最新产品');
      expect(subs[1].shotStart, 2);
      expect(subs[1].shotEnd, 3);
    });

    test('没有切点 = 整句一组；json 往返不丢', () {
      final line = line3shots();
      expect(line.sublines.single.text, '家人们，这是我们的最新产品');
      final cut = line.withSublineCuts(const [(4, 2)]);
      final back = ScriptLine.tryFromJson(cut.toJson())!;
      expect(back.sublineCuts, const [(4, 2)]);
    });

    test('镜头删得只剩 1 个后越界切点自动失效，不炸', () {
      final line = line3shots()
          .withSublineCuts(const [(4, 2)])
          .withShots(const [
        LineShot(materialId: 1, name: 'a', durationMs: 4000, allocMs: 2000),
      ]);
      expect(line.sublines, hasLength(1), reason: '切点越界即整句一组');
    });

    test('小行的时间区间 = 组内镜头 allocMs 累计（字幕显示用）', () {
      final line = line3shots().withSublineCuts(const [(4, 2)]);
      final spans = line.sublineSpans;
      expect(spans[0].startMs, 0);
      expect(spans[0].endMs, 3000, reason: '前两镜 2000+1000');
      expect(spans[1].startMs, 3000);
      expect(spans[1].endMs, 5000);
    });
  });

  group('序列化', () {
    test('json 往返一字不差', () {
      var doc = ScriptDoc.empty();
      doc = doc
          .updateText(0, '第一句')
          .insertAfter(0)
          .setManualMs(1, 3000)
          .insertAfter(1, text: '第三句');
      final back = ScriptDoc.fromJson(doc.toJson());
      expect(back.toJson(), doc.toJson());
      expect(back.lines[1].manualMs, 3000);
      expect(back.lines[2].text, '第三句');
    });

    test('认不出的 json 不炸——退回空脚本', () {
      expect(ScriptDoc.fromJson({'lines': '坏数据'}).lines, hasLength(1));
    });
  });
}
