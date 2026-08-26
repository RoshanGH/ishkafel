import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/script_view.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/script/script_doc.dart';

/// Agent 干任何事之前先要能看懂这个任务。这份投影就是它的全部事实来源，
/// 字段名不能随手改——改一次就把所有调用方打断一次。
void main() {
  LineVoiceover vo(int ms, {List<VoiceWord> words = const []}) => LineVoiceover(
      audioPath: '/vo.mp3',
      durationMs: ms,
      sourceText: '词',
      voiceId: 'v',
      speechRate: 0,
      words: words);

  RenewTask task(ScriptDoc doc) => RenewTask(
        id: 'hlhivnohoo',
        seq: 2,
        name: '脚本 08-19',
        sourcePath: null,
        script: doc,
        status: RenewTaskStatus.ready,
        createdAt: DateTime.utc(2026, 8, 19),
        updatedAt: DateTime.utc(2026, 8, 19),
      );

  test('全貌：行、配音、镜头、参考镜、字幕屏都投影出来', () {
    final doc = ScriptDoc([
      ScriptLine.create(text: '再不买就恢复69.9一瓶了')
          .withTags(['促单'])
          .withShots(const [
            LineShot(
                materialId: 105310,
                name: '滴露_厨房',
                sceneDescription: '厨房里手持喷雾瓶',
                durationMs: 16300,
                allocMs: 3048),
          ])
          .withVoiceover(vo(3048, words: const [
            VoiceWord(text: '再', startMs: 0, endMs: 200),
          ])),
    ]);
    final json = scriptTaskJson(task(doc));

    expect(json['kind'], 'script');
    expect(json['id'], 'hlhivnohoo');
    final line = (json['lines'] as List).single as Map;
    expect(line['index'], 0);
    expect(line['type'], 'voiced');
    expect(line['rootMs'], 3048, reason: '配音时长是这一行的根，分时长靠它');
    expect(line['voice']['hasWordTimings'], isTrue,
        reason: '没有逐字时间就不能外包断句——必须让调用方看得见');
    final shot = (line['shots'] as List).single as Map;
    expect(shot['availableMs'], 16300,
        reason: '这条素材还能出多长，是挑镜头与分时长的前提');
    expect(shot['sceneDescription'], '厨房里手持喷雾瓶');
    expect(line['subtitle']['maxCharsPerScreen'], isA<int>(),
        reason: '每屏字数上限由字号推出，断句要守这条');
  });

  test('画面铺不满的镜头进 blocking——Agent 提交完要能自查', () {
    final doc = ScriptDoc([
      ScriptLine.create(text: '台词')
          .withShots(const [
            LineShot(
                materialId: 106720, name: '短素材', durationMs: 1207, allocMs: 6048),
          ])
          .withVoiceover(vo(6048)),
    ]);
    final blocking = scriptTaskJson(task(doc))['blocking'] as List;
    expect(blocking, hasLength(1));
    expect(blocking.single['kind'], 'shot-too-short');
    expect('${blocking.single['message']}', contains('1.2'));
  });

  test('参考镜的画面描述要给——那是复刻的依据', () {
    final doc = ScriptDoc([
      ScriptLine.create(text: '台词').withReference(LineRef(
          startMs: 0,
          endMs: 3000,
          cuts: const [1200],
          shotMeta: [
            RefShotMeta(
                startMs: 0, description: '手持喷雾瓶', tags: const ['产品特写']),
          ])),
    ]);
    final line = (scriptTaskJson(task(doc))['lines'] as List).single as Map;
    final refShots = line['reference']['shots'] as List;
    expect(refShots, hasLength(2), reason: '一刀切出两镜');
    expect(refShots.first['description'], '手持喷雾瓶');
    expect(refShots.first['tags'], ['产品特写']);
  });

  test('不是脚本任务就明说，不要冒充一个空脚本', () {
    final notScript = RenewTask(
      id: 't9',
      seq: 1,
      name: '成片翻新',
      sourcePath: '/v/a.mp4',
      status: RenewTaskStatus.ready,
      createdAt: DateTime.utc(2026, 8, 19),
      updatedAt: DateTime.utc(2026, 8, 19),
    );
    expect(() => scriptTaskJson(notScript), throwsArgumentError);
  });

  test('单行详情：断句材料另有出口，这里只给概览', () {
    final doc = ScriptDoc([
      ScriptLine.create(text: '第一句').withVoiceover(vo(3000)),
      ScriptLine.create(text: '第二句').withVoiceover(vo(4000)),
    ]);
    final line = scriptLineJson(doc, 1);
    expect(line['index'], 1);
    expect(line['text'], '第二句');
    expect(() => scriptLineJson(doc, 9), throwsArgumentError);
  });
}
