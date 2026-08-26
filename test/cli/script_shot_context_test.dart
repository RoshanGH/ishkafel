import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/script_shot_context.dart';
import 'package:ishkafel/core/script/script_doc.dart';

/// 挑镜头需要的不只是候选列表，还有**判断的依据**。
/// 软件把事实摆全，「怎么挑得好」归 skill（spec 第一节）。
void main() {
  LineVoiceover vo(int ms) => LineVoiceover(
      audioPath: '/vo.mp3',
      durationMs: ms,
      sourceText: '词',
      voiceId: 'v',
      speechRate: 0);

  ScriptDoc threeLines() => ScriptDoc([
        ScriptLine.create(text: '第一句')
            .withShots(const [
              LineShot(
                  materialId: 105310,
                  name: '厨房特写',
                  sceneDescription: '在现代厨房中，一只右手举着喷雾瓶',
                  durationMs: 9000,
                  allocMs: 3000),
            ])
            .withVoiceover(vo(3000)),
        ScriptLine.create(text: '如果你觉得有点贵')
            .withTags(['促单'])
            .withVoiceover(vo(8880))
            .withReference(LineRef(startMs: 0, endMs: 8880, shotMeta: [
              RefShotMeta(
                  startMs: 0,
                  description: '镜头在厨房内，前景一只手拿着喷雾瓶',
                  tags: const ['产品特写', '实拍']),
            ])),
        ScriptLine.create(text: '第三句').withVoiceover(vo(4000)),
      ]);

  test('把判断的依据一次给全：坑位、参考镜、前后镜头、已用素材', () {
    final ctx = scriptShotContext(threeLines(), 1);

    expect(ctx['slotMs'], 8880, reason: '坑位多长决定素材够不够铺');
    expect((ctx['reference'] as List).single['description'],
        contains('喷雾瓶'), reason: '要复刻的就是参考片这一镜');
    expect(ctx['neighbors']['prev']['shots'], hasLength(1),
        reason: '前后是什么画面，决定连起来顺不顺');
    expect(ctx['usedElsewhere'], contains(105310),
        reason: '整片已用的要避开，否则几句话撞同一条');
  });

  test('参考镜还没打标：如实说没有，并说清下一步', () {
    final doc = ScriptDoc([
      ScriptLine.create(text: '台词')
          .withVoiceover(vo(3000))
          .withReference(LineRef(startMs: 0, endMs: 3000)),
    ]);
    final ctx = scriptShotContext(doc, 0);
    expect((ctx['reference'] as List).single['description'], isEmpty);
    expect('${ctx['hint']}', contains('还没打标'),
        reason: '没有依据要说出来，让调用方知道该先打标');
  });

  test('压根没有参考片：也要说清楚——这时只能靠台词和标签', () {
    final doc = ScriptDoc([
      ScriptLine.create(text: '台词').withVoiceover(vo(3000)),
    ]);
    final ctx = scriptShotContext(doc, 0);
    expect(ctx['reference'], isEmpty);
    expect('${ctx['hint']}', contains('没有参考片'));
  });

  test('首尾行的相邻给 null，不要编一个', () {
    final ctx = scriptShotContext(threeLines(), 0);
    expect(ctx['neighbors']['prev'], isNull);
    expect(ctx['neighbors']['next'], isNotNull);
  });

  test('行号越界直接拒绝', () {
    expect(() => scriptShotContext(threeLines(), 9), throwsArgumentError);
  });
}
