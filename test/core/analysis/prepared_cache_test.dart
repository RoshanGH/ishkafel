import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/analysis_pipeline.dart';
import 'package:ishkafel/core/analysis/prepared_cache.dart';
import 'package:ishkafel/core/analysis/segmentation_builder.dart';
import 'package:ishkafel/core/analysis/providers.dart';

/// 同一条片子导三次切出 3/4/5 个单元——语义切分是 LLM 干的，有随机性。
/// 于是方案文件不能跨任务复用（`unit 2 shot 3` 在新任务里指向别的画面），
/// 「1:1 复刻」也打了折扣。
///
/// 按源文件内容缓存分析产物：同一个文件重新导入直接复用，
/// 结构就稳定了，还省掉一次 ASR + LLM（真金白银）。
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('pc'));
  tearDown(() => dir.deleteSync(recursive: true));

  PreparedAnalysis prepared({int sentences = 2}) => PreparedAnalysis(
        sentences: [
          for (var i = 0; i < sentences; i++)
            AsrSentence(
                startMs: i * 1000, endMs: i * 1000 + 900, text: '第 $i 句'),
        ],
        valleys: const [1000, 2000],
        shotBounds: const [0, 500, 1500],
      );

  test('存了就能按指纹取回来', () {
    final cache = PreparedCache(dir);

    cache.save('print1', prepared());
    final got = cache.load('print1');

    expect(got, isNotNull);
    expect(got!.sentences, hasLength(2));
    expect(got.valleys, [1000, 2000]);
    expect(got.shotBounds, [0, 500, 1500]);
  });

  test('换个文件（指纹不同）取不到——不能张冠李戴', () {
    final cache = PreparedCache(dir);
    cache.save('print1', prepared());

    expect(cache.load('print2'), isNull);
  });

  test('缓存文件坏了当作没有，不让整条导入失败', () {
    final cache = PreparedCache(dir);
    cache.save('print1', prepared());
    File('${dir.path}/prepared/print1.json').writeAsStringSync('{坏的');

    expect(cache.load('print1'), isNull);
  });

  test('指纹为 null 时既不存也不取——那是「算不出指纹」，不是一个键', () {
    final cache = PreparedCache(dir);

    cache.save(null, prepared());
    expect(cache.load(null), isNull);
    expect(Directory('${dir.path}/prepared').existsSync(), isFalse);
  });

  /// **语义切分才是随机性的来源**：ASR 句子是稳定的，而按语义分组是 LLM 干的。
  /// 真机上缓存了 ASR 之后，同一条片子照样切出 4 个和 3 个单元——
  /// 差别全在这一步。
  group('语义切分草稿也要缓存', () {
    List<UnitDraft> drafts() => const [
          UnitDraft(startMs: 0, endMs: 16033, transcript: '第一段'),
          UnitDraft(startMs: 16033, endMs: 38000, transcript: '第二段'),
        ];

    test('存了就能取回来，边界一模一样', () {
      final cache = PreparedCache(dir);
      cache.saveDrafts('p1', drafts());

      final got = cache.loadDrafts('p1');

      expect(got, hasLength(2));
      expect(got![1].startMs, 16033);
      expect(got[1].endMs, 38000);
    });

    test('一条读不动就整份作废——缺一段的切分比没有更危险', () {
      final cache = PreparedCache(dir);
      cache.saveDrafts('p1', drafts());
      File('${dir.path}/prepared/p1.drafts.json')
          .writeAsStringSync('[{"startMs":0,"endMs":100},{"startMs":"坏"}]');

      expect(cache.loadDrafts('p1'), isNull);
    });

    test('空的切分不存——存了会让下次拿到一个没有单元的片子', () {
      final cache = PreparedCache(dir);
      cache.saveDrafts('p2', const []);

      expect(cache.loadDrafts('p2'), isNull);
    });
  });

}
