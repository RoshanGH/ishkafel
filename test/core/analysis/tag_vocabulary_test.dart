import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/tag_vocabulary.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart';
import 'package:ishkafel/core/miaoa/miaoa_gateway.dart';

const _tagListJson = '''
[
  {"id":18495,"tagGroupId":1279,"tagName":"洗内裤","tagType":"TENANT","isEnabled":true},
  {"id":18496,"tagGroupId":1279,"tagName":"洗袜子","tagType":"TENANT","isEnabled":true}
]
''';

void main() {
  test('把标签组内的标签名取成受控词表', () async {
    final source = MiaoaTagVocabularySource(MiaoaTagService(gateway: MiaoaGateway(run: (_, _) async => ProcessResult(1, 0, _tagListJson, ''), binary: 'miaoa')));

    expect(await source.vocabularyOf(1279), ['洗内裤', '洗袜子']);
  });

  test('按传入的组 id 查（不同任务查不同组）', () async {
    final asked = <String>[];
    final source = MiaoaTagVocabularySource(MiaoaTagService(gateway: MiaoaGateway(run: (_, args) async {
      asked.add(args.join(' '));
      return ProcessResult(1, 0, _tagListJson, '');
    }, binary: 'miaoa')));

    await source.vocabularyOf(1279);
    await source.vocabularyOf(136);

    expect(asked, ['tag list --group 1279 --json', 'tag list --group 136 --json']);
  });

  test('返回不可变列表，不把可变集合交给外部', () async {
    final source = MiaoaTagVocabularySource(MiaoaTagService(gateway: MiaoaGateway(run: (_, _) async => ProcessResult(1, 0, _tagListJson, ''), binary: 'miaoa')));

    final vocab = await source.vocabularyOf(1279);
    expect(() => vocab.add('x'), throwsUnsupportedError);
  });

  test('CLI 失败原样抛出，由调用方决定降级策略（不静默吞成空词表）', () async {
    final source = MiaoaTagVocabularySource(MiaoaTagService(gateway: MiaoaGateway(run: (_, _) async => ProcessResult(1, 1, '', '401 Unauthorized'), binary: 'miaoa')));

    await expectLater(source.vocabularyOf(1279), throwsA(isA<MiaoaException>()));
  });
}
