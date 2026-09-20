import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/core/subtitle/voice_source.dart';

/// 这一镜的台词从哪来——**四态必须分开**。
///
/// 四种「没台词」长得一模一样的话，Agent 会把「这一段本来就没字幕」
/// 当成漏字去修。这是「三态混成两态」那个洞的预防。
void main() {
  const shot = Shot(startMs: 0, endMs: 1000);

  SemanticUnit unit({bool hasSource = true, int? baseCandidateId}) =>
      SemanticUnit(
        uid: 'u0', index: 0, startMs: 0, endMs: 1000, transcript: '一句',
        hasSource: hasSource,
        baseCandidateId: baseCandidateId,
        shots: const [shot],
      );

  test('声音来自原片：ASR 可用', () {
    final r = voiceSourceOf(
        unit: unit(), replacement: UnitReplacement.keepOriginal());
    expect(r.source, VoiceSource.original);
    expect(r.note, contains('原片'));
  });

  test('整段替换：原片 ASR 一个字都不能用', () {
    final r = voiceSourceOf(
      unit: unit(),
      replacement: UnitReplacement.whole(const [101]),
    );
    expect(r.source, VoiceSource.replaced);
    expect(r.note, contains('一个字都不能用'),
        reason: '不把这句说死，Agent 会拿原片台词去对一段毫不相干的画面');
  });

  test('整段替换但一条候选都没挑：画面照旧，ASR 还能用', () {
    final r = voiceSourceOf(
      unit: unit(),
      replacement: UnitReplacement.whole(const []),
    );
    expect(r.source, VoiceSource.original,
        reason: '「还没挑」不是「换掉了」——混为一谈会把没动过的段落也标成没台词');
  });

  test('固定过底片：台词来自素材自己的转写', () {
    final r = voiceSourceOf(
        unit: unit(baseCandidateId: 77),
        replacement: UnitReplacement.keepOriginal());
    expect(r.source, VoiceSource.base);
  });

  test('手动加的单元：原片里没有它，没有台词来源', () {
    final r = voiceSourceOf(
        unit: unit(hasSource: false),
        replacement: UnitReplacement.keepOriginal());
    expect(r.source, VoiceSource.none);
  });
}
