import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/volcano_semantic_splitter.dart';
import 'package:ishkafel/core/analysis/providers.dart';

const _sentences = [
  AsrSentence(startMs: 0, endMs: 1000, text: '第一句。'),
  AsrSentence(startMs: 1000, endMs: 2000, text: '第二句。'),
  AsrSentence(startMs: 2000, endMs: 3000, text: '第三句。'),
  AsrSentence(startMs: 3000, endMs: 4000, text: '第四句。'),
];

List<int> _reasonsOf(String reply) {
  final reasons = <SemanticSplitDegradation>[];
  VolcanoSemanticSplitter.parseGrouping(reply, _sentences,
      onDegraded: reasons.add);
  return [for (final r in reasons) r.index];
}

void main() {
  group('只要切点：任何一个切点列表都天然是合法分组', () {
    test('按切点分段，段内的句子自动归拢', () {
      final drafts =
          VolcanoSemanticSplitter.parseGrouping('{"starts":[0,2]}', _sentences);

      expect(drafts, hasLength(2));
      expect(drafts[0].transcript, '第一句。第二句。');
      expect(drafts[1].transcript, '第三句。第四句。');
      expect(drafts[0].startMs, 0);
      expect(drafts[1].endMs, 4000);
    });

    test('切点乱序、重复、越界都不构成降级——这正是换协议的目的', () {
      expect(_reasonsOf('{"starts":[2,0,2,99]}'), isEmpty,
          reason: '旧协议里这些都会让整份分组作废，'
              '真机上 27 句 ASR 因此被切成 27 个单元');

      final drafts = VolcanoSemanticSplitter.parseGrouping(
          '{"starts":[2,0,2,99]}', _sentences);
      expect(drafts, hasLength(2));
    });

    test('没给 0 也自动从头开始，一句不落', () {
      final drafts =
          VolcanoSemanticSplitter.parseGrouping('{"starts":[2]}', _sentences);

      expect(drafts.map((d) => d.transcript).join(),
          _sentences.map((s) => s.text).join());
    });

    test('切点为空时退回每句一个，并如实上报', () {
      final reasons = <SemanticSplitDegradation>[];
      final drafts = VolcanoSemanticSplitter.parseGrouping(
          '{"starts":[]}', _sentences,
          onDegraded: reasons.add);

      expect(drafts, hasLength(4));
      expect(reasons, [SemanticSplitDegradation.invalidPartition]);
    });

    test('模型裹了 markdown 代码块也读得出来', () {
      final drafts = VolcanoSemanticSplitter.parseGrouping(
          '```json\n{"starts":[0,2]}\n```', _sentences);

      expect(drafts, hasLength(2));
    });
  });

  group('旧协议仍然读得懂——模型偶尔会按老格式答', () {
    test('合法的分组照常用，不报降级', () {
      final reasons = <SemanticSplitDegradation>[];
      final drafts = VolcanoSemanticSplitter.parseGrouping(
          '{"units":[{"sentenceIndexes":[0,1]},{"sentenceIndexes":[2,3]}]}',
          _sentences,
          onDegraded: reasons.add);

      expect(drafts, hasLength(2));
      expect(reasons, isEmpty);
    });

    test('有瑕疵的分组按它给的切点补齐，并上报「已修复」', () {
      final reasons = <SemanticSplitDegradation>[];
      final drafts = VolcanoSemanticSplitter.parseGrouping(
          '{"units":[{"sentenceIndexes":[0]},{"sentenceIndexes":[2]}]}',
          _sentences,
          onDegraded: reasons.add);

      expect(drafts, hasLength(2));
      expect(reasons, [SemanticSplitDegradation.repairedPartition]);
    });
  });

  test('完全读不懂时才退回每句一个', () {
    final reasons = <SemanticSplitDegradation>[];
    final drafts = VolcanoSemanticSplitter.parseGrouping('抱歉我不明白', _sentences,
        onDegraded: reasons.add);

    expect(drafts, hasLength(4));
    expect(reasons, [SemanticSplitDegradation.unparsableOutput]);
  });
}
