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

    test('有镜头跨度：参考镜是完整镜头，超出台词边界也照给', () {
      final ref = LineRef(
        startMs: 3200,
        endMs: 9500,
        shotStartMs: 3000,
        shotEndMs: 12000,
        cuts: const [8000],
      );
      expect(ref.hasWholeShots, isTrue);
      expect(ref.segments, [(3000, 8000), (8000, 12000)]);
      expect(ref.durationMs, 6300, reason: '台词层的时长仍是台词自己的');
    });

    test('老档没有镜头跨度：退回台词边界切（不能读崩、不能丢数据）', () {
      final back = LineRef.tryFromJson({
        'startMs': 1000,
        'endMs': 4000,
        'cuts': [2000],
      })!;
      expect(back.hasWholeShots, isFalse);
      expect(back.segments, [(1000, 2000), (2000, 4000)]);
    });

    test('镜头跨度随 json 往返；withCuts / withShotMeta 都留着它', () {
      final ref = LineRef(
        startMs: 3200,
        endMs: 9500,
        shotStartMs: 3000,
        shotEndMs: 12000,
        cuts: const [8000],
      );
      final back = LineRef.tryFromJson(ref.toJson())!;
      expect(back.shotStartMs, 3000);
      expect(back.shotEndMs, 12000);
      expect(back.withCuts(const [7000]).shotStartMs, 3000);
      expect(
          back.withShotMeta(RefShotMeta(startMs: 3000, description: '一只手'))
              .shotEndMs,
          12000);
    });

    test('切点变了 → 旧的镜头打标自动作废，不拿旧结论去搜新画面', () {
      final ref = LineRef(
        startMs: 3200,
        endMs: 9500,
        shotStartMs: 3000,
        shotEndMs: 12000,
        cuts: const [8000],
      ).withShotMeta(RefShotMeta(startMs: 3200, description: '老边界打的标'));
      expect(ref.metaAt(3200)?.description, '老边界打的标');
      expect(ref.metaAt(ref.segments.first.$1), isNull,
          reason: '边界从 3200 变成 3000，认领不上就重打——不崩、也不错用');
    });
  });

  group('字幕屏（切点跟语言走，与镜头无关）', () {
    const long = '家人们你好呀，这是我们今年最新的爆款产品啊，真的很好用哦';

    ScriptLine lineWith(List<LineShot> shots,
        {String text = long, int durationMs = 7000}) {
      return ScriptLine.create(text: text).withShots(shots).withVoiceover(
            LineVoiceover(
              audioPath: '/vo.mp3',
              durationMs: durationMs,
              sourceText: text,
              voiceId: 'v',
              speechRate: 0,
              words: [
                for (var i = 0; i < text.replaceAll('，', '').length; i++)
                  VoiceWord(
                      text: text.replaceAll('，', '')[i],
                      startMs: (i * durationMs /
                              text.replaceAll('，', '').length)
                          .round(),
                      endMs: (i * durationMs /
                                  text.replaceAll('，', '').length)
                              .round() +
                          180),
              ],
            ),
          );
    }

    test('长台词自动分屏依次出现，不堆在画面上；字不丢、时间递增', () {
      final line = lineWith(const [
        LineShot(materialId: 1, name: 'a', durationMs: 30000, allocMs: 7000),
      ]);
      final segs = line.subtitleScreensAt();
      expect(segs.length, greaterThan(1),
          reason: '一个长镜头下字幕该一屏一屏出，而不是一次堆上去');
      expect(segs.first.startMs, 0, reason: '第一屏从行首就在');
      expect(segs.last.endMs, 7000, reason: '最后一屏留到行末尾');
      for (var i = 1; i < segs.length; i++) {
        expect(segs[i].startMs, segs[i - 1].endMs, reason: '屏与屏无缝衔接');
      }
    });

    test('切一刀 = 只记切点：改镜头时长后字幕自愈，不重复不丢屏', () {
      var line = lineWith(const [
        LineShot(materialId: 1, name: 'a', durationMs: 30000, allocMs: 4000),
        LineShot(materialId: 2, name: 'b', durationMs: 30000, allocMs: 3000),
      ]);
      line = line.cutSubtitleAt(2000);
      final before = line.subtitleScreensAt();
      // 把第一镜从 4 秒缩到 1.6 秒（第二镜补上）——屏该原样还在
      line = line.withShots(const [
        LineShot(materialId: 1, name: 'a', durationMs: 30000, allocMs: 1600),
        LineShot(materialId: 2, name: 'b', durationMs: 30000, allocMs: 5400),
      ]);
      final after = line.subtitleScreensAt();
      expect(after.map((s) => s.text).toList(),
          before.map((s) => s.text).toList(),
          reason: '切点跟语言走，与镜头时长无关——不该重复也不该丢屏');
      expect(after.map((s) => s.text).toSet().length, after.length,
          reason: '同一段字不许出现两遍');
    });

    test('手写某一屏只改那一屏；标点一律剥掉（预览与成片同一份）', () {
      var line = lineWith(const [
        LineShot(materialId: 1, name: 'a', durationMs: 30000, allocMs: 7000),
      ]);
      line = line.setSubtitleScreenText(0, '家人们，你好呀！');
      final segs = line.subtitleScreensAt();
      expect(segs.first.text, '家人们你好呀',
          reason: '手写的标点也剥——四处显示同一套规则');
      expect(segs.length, greaterThan(1), reason: '别的屏不受影响');
    });

    test('某一屏可以显式不出字（纯画面镜）', () {
      var line = lineWith(const [
        LineShot(materialId: 1, name: 'a', durationMs: 30000, allocMs: 7000),
      ]);
      final n = line.subtitleScreensAt().length;
      line = line.setSubtitleScreenText(0, '');
      expect(line.subtitleScreensAt().length, n - 1);
    });

    test('并回上一屏；恢复自动 = 清掉切点', () {
      var line = lineWith(const [
        LineShot(materialId: 1, name: 'a', durationMs: 30000, allocMs: 7000),
      ]);
      line = line.cutSubtitleAt(2000);
      final cut = line.subtitleScreensAt().length;
      line = line.mergeSubtitleScreen(1);
      expect(line.subtitleScreensAt().length, lessThan(cut));
      line = line.withSubtitleScreens(null);
      expect(line.subtitleScreens, isNull, reason: '恢复自动');
    });

    test('停顿一样大时不许一个字一屏——屏要尽量装满', () {
      const src = '家人们你好呀这是我们今年最新的爆款产品真的很好用';
      final line = ScriptLine.create(text: src).withShots(const [
        LineShot(materialId: 1, name: 'a', durationMs: 9000, allocMs: 6000),
      ]).withVoiceover(LineVoiceover(
        audioPath: '/vo.mp3',
        durationMs: 6000,
        sourceText: src,
        voiceId: 'v',
        speechRate: 0,
        // 逐字等距：词间停顿完全一样大（真机就是这样）
        words: [
          for (var i = 0; i < src.length; i++)
            VoiceWord(
                text: src[i],
                startMs: (i * 6000 / src.length).round(),
                endMs: (i * 6000 / src.length).round() + 200),
        ],
      ));
      final segs = line.subtitleScreensAt(maxChars: 15);
      expect(segs, hasLength(2), reason: '24 个字按 15 字上限就是两屏');
      expect(segs.first.text.length, greaterThanOrEqualTo(10),
          reason: '第一屏要装满，不能只切走一两个字');
      expect(segs.map((s) => s.text).join(), src, reason: '一个字都不许丢');
    });

    test('ASR 词表与原文对不齐时不炸屏，价格照原文写', () {
      // 真机数据：「69.9一」被 ASR 并成一个词 "69.91"。以前这会让
      // 标点还原把整段原文塞进一个词里，字数爆炸 → 一个字一屏；
      // 而照词拼接又会把价格写成「69.91瓶」
      const src = '再不买就恢复69.9一瓶了。';
      final line = ScriptLine.create(text: src).withShots(const [
        LineShot(materialId: 1, name: 'a', durationMs: 9000, allocMs: 3000),
      ]).withVoiceover(LineVoiceover(
        audioPath: '/vo.mp3',
        durationMs: 3000,
        sourceText: src,
        voiceId: 'v',
        speechRate: 0,
        words: const [
          VoiceWord(text: '再', startMs: 330, endMs: 490),
          VoiceWord(text: '不', startMs: 490, endMs: 690),
          VoiceWord(text: '买', startMs: 690, endMs: 890),
          VoiceWord(text: '就', startMs: 890, endMs: 1130),
          VoiceWord(text: '恢', startMs: 1130, endMs: 1290),
          VoiceWord(text: '复', startMs: 1290, endMs: 1410),
          VoiceWord(text: '69.91', startMs: 1410, endMs: 2330),
          VoiceWord(text: '瓶', startMs: 2330, endMs: 2490),
          VoiceWord(text: '了', startMs: 2530, endMs: 2730),
        ],
      ));
      final segs = line.subtitleScreensAt(maxChars: 15);
      expect(segs, hasLength(1), reason: '13 个字装得下一屏，不许一个字一屏');
      expect(segs.single.text, '再不买就恢复69.9一瓶了',
          reason: '字幕按原文出，不按 ASR 词表拼——价格不许写错');
    });

    test('老配音没有逐字时间：照样分屏（不堆字），时间按字数摊', () {
      const src = '你宁愿冰箱发霉有异味，也不愿意试试这个滴露除菌喷雾吗？';
      final line = ScriptLine.create(text: src).withShots(const [
        LineShot(materialId: 1, name: 'a', durationMs: 9000, allocMs: 5000),
      ]).withVoiceover(LineVoiceover(
        audioPath: '/vo.mp3',
        durationMs: 5000,
        sourceText: src,
        voiceId: 'v',
        speechRate: 0,
      ));
      final segs = line.subtitleScreensAt(maxChars: 15);
      expect(segs.length, greaterThan(1), reason: '26 个字不能堆在画面上');
      expect(segs.first.startMs, 0);
      expect(segs.last.endMs, 5000);
      expect(segs.map((s) => s.text).join(),
          '你宁愿冰箱发霉有异味也不愿意试试这个滴露除菌喷雾吗',
          reason: '一个字都不许丢');
    });

    test('屏与切点 json 往返不丢', () {
      var line = lineWith(const [
        LineShot(materialId: 1, name: 'a', durationMs: 30000, allocMs: 7000),
      ]);
      line = line.cutSubtitleAt(2000).setSubtitleScreenText(0, '改过的');
      final back = ScriptLine.tryFromJson(line.toJson())!;
      expect(back.subtitleScreens!.map((s) => s.startWord).toList(),
          line.subtitleScreens!.map((s) => s.startWord).toList());
      expect(back.subtitleScreens!.first.text, '改过的');
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
