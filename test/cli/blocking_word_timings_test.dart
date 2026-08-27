import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/script_view.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/script/script_doc.dart';

/// 配音没有逐字时间 → 断不了句 → 字幕整句糊在屏幕上。
///
/// 真机撞到：第 16 句「加一点。」的 ASR 报 no valid speech in audio，
/// 那一行 `hasWordTimings=false`，但 `blocking` 是空的、导出照过。
/// 这正是手册自己批评的「导得出来但片子是坏的」那一类。
void main() {
  RenewTask taskOf(ScriptDoc doc) => RenewTask(
        id: 't1',
        name: '片子',
        sourcePath: null,
        status: RenewTaskStatus.ready,
        createdAt: DateTime.utc(2026, 8, 28),
        updatedAt: DateTime.utc(2026, 8, 28),
        units: const [],
        script: doc,
      );

  LineVoiceover vo({List<VoiceWord> words = const []}) => LineVoiceover(
        audioPath: '/v.mp3',
        durationMs: 800,
        sourceText: '加一点。',
        voiceId: 'v',
        speechRate: 0,
        words: words,
      );

  List blockingOf(ScriptDoc doc) =>
      scriptTaskJson(taskOf(doc))['blocking'] as List;

  test('没有逐字时间的行要被拦下来并点名', () {
    var doc = ScriptDoc([ScriptLine.create(text: '加一点。')]);
    doc = doc.setVoiceoverById(doc.lines.first.id, vo());
    final b = blockingOf(doc);
    expect(b, hasLength(1));
    expect((b.first as Map)['kind'], 'no-word-timings');
    expect('${(b.first as Map)['message']}', contains('script voice'),
        reason: '要给出下一步怎么办，不能只说坏了');
  });

  test('有逐字时间就不拦', () {
    var doc = ScriptDoc([ScriptLine.create(text: '加一点。')]);
    doc = doc.setVoiceoverById(
        doc.lines.first.id,
        vo(words: const [VoiceWord(text: '加', startMs: 0, endMs: 200)]));
    expect(blockingOf(doc), isEmpty);
  });

  test('还没配音的行不算——那是「还没做」，不是「做坏了」', () {
    expect(blockingOf(ScriptDoc([ScriptLine.create(text: '还没配音')])), isEmpty);
  });

  test('画面行不算', () {
    expect(blockingOf(ScriptDoc([ScriptLine.create(text: '')])), isEmpty);
  });
}
