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
