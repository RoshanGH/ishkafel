import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/script/shot_allocation.dart';

/// 重排一行镜头时长的**唯一入口**。
///
/// 真机 bug：人先划词建了两个镜（时长按朗读长短算好了），再用「找镜头」
/// 加两个镜——那条路径调的是老的均分函数，不认识划词镜，把整行重新平摊，
/// 4 个镜头全变成 8880÷4=2220ms。划的词等于白划，而且不报错、不提示。
///
/// 根因是「同一个东西两处算」：9 个调用点各自决定用哪个函数，漏一个就
/// 悄悄错。所以收敛成这一个入口——它自己判断有没有划词镜。
void main() {
  final words = [
    for (var i = 0; i < 20; i++)
      VoiceWord(text: '字', startMs: i * 400, endMs: (i + 1) * 400),
  ];
  final vo = LineVoiceover(
    audioPath: '/v.mp3',
    durationMs: 8000,
    sourceText: '字' * 20,
    voiceId: 'v',
    speechRate: 0,
    words: words,
  );

  LineShot bound(int s, int e) => LineShot(
      materialId: s + 1, name: 'b$s', durationMs: 99999,
      startWord: s, endWord: e);
  const free = LineShot(materialId: 99, name: '自由', durationMs: 99999);

  test('有划词镜：按朗读时长算，自由镜分剩下的', () {
    final line = ScriptLine.create(text: vo.sourceText).withVoiceover(vo);
    final r = reallocShots(line, [bound(0, 5), bound(5, 12), free, free]);
    expect(r[0].allocMs, 2000, reason: '前 5 个字');
    expect(r[1].allocMs, 2800, reason: '接下来 7 个字');
    expect(r[2].allocMs! + r[3].allocMs!, 8000 - 2000 - 2800);
  });

  test('没有划词镜：退回均分，行为和以前一样', () {
    final line = ScriptLine.create(text: vo.sourceText).withVoiceover(vo);
    final r = reallocShots(line, [free, free]);
    expect(r[0].allocMs, 4000);
    expect(r[1].allocMs, 4000);
  });

  test('画面行（手填时长）也能重排', () {
    final line = ScriptLine.create(text: '').withManualMs(6000);
    final r = reallocShots(line, [free, free]);
    expect(r[0].allocMs! + r[1].allocMs!, 6000);
  });

  test('没有根（没配音也没手填）就原样返回，不瞎分', () {
    final line = ScriptLine.create(text: '有词但还没配音');
    final r = reallocShots(line, [free, free]);
    expect(r.every((s) => s.allocMs == null), isTrue);
  });

  test('这正是被冲掉的那个场景：划两个词镜之后再加两个自由镜', () {
    final line = ScriptLine.create(text: vo.sourceText).withVoiceover(vo);
    final after = reallocShots(line, [bound(0, 8), bound(8, 18), free, free]);
    expect(after[0].allocMs, isNot(after[1].allocMs),
        reason: '8 个字和 10 个字读的时间不可能相等——相等就说明被平摊了');
  });
}
