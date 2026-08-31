import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/task_status.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/script/script_doc.dart';

/// 接手一条被打断的活儿：**先知道干到哪了，再决定下一步敲什么**。
///
/// 用户提的需求：「之前操作被停止的，我关了 app，去 Codex 那里让他继续，
/// 他能正常接着做吗？不用重复搞……他能不能有一个方式知道现在各个项目的
/// 具体情况，然后根据上下文继续做。因为有可能我在打断他的时候我人为地做了
/// 些操作，他要有感知地去继续操作。」
///
/// 不给这个的话，接手的 Agent 只能照流程从头再走一遍——重新打标
/// （十几分钟、几十次识图）、重新配音（一轮 TTS），全是白花的钱。
void main() {
  // sourceText 要和台词一致，否则会被正确地判成「台词改了、配音过期」
  LineVoiceover vo(String text) => LineVoiceover(
        audioPath: '/a.mp3',
        durationMs: 1000,
        sourceText: text,
        voiceId: 'vivi',
        speechRate: 0,
        words: const [],
      );

  RenewTask taskWith(ScriptDoc doc) => RenewTask(
        id: 't1',
        name: '复刻',
        status: RenewTaskStatus.ready,
        createdAt: DateTime(2026, 8, 31),
        updatedAt: DateTime(2026, 8, 31),
        script: doc,
      );

  test('空任务：下一步是把台词搞出来', () {
    final s = statusOf(taskWith(ScriptDoc(const [])));
    expect(s.stage, contains('还没有台词'));
    expect(s.next, contains('script extract'));
  });

  test('参考镜没打完：直接指到还差的那一句', () {
    final doc = ScriptDoc([
      ScriptLine.create(
          text: '一',
          reference: LineRef(startMs: 0, endMs: 100, cuts: const []))
          .withVoiceover(vo('一')),
      ScriptLine.create(
          text: '二',
          reference: LineRef(startMs: 100, endMs: 200, cuts: const [])),
    ], refVideoPath: '/片.mp4');
    final s = statusOf(taskWith(doc));
    expect(s.stage, contains('打标'));
    expect(s.next, contains('tag-ref'),
        reason: '要给能直接敲的那条，不是让人自己找哪句没打');
  });

  test('配音齐了、没挑镜头：指到第一行没挑的', () {
    final doc = ScriptDoc([
      ScriptLine.create(text: '一').withVoiceover(vo('一')).withShots(const [
        LineShot(materialId: 1, name: 'a', durationMs: 3000, allocMs: 1000),
      ]),
      ScriptLine.create(text: '二').withVoiceover(vo('二')),
    ]).withDefaultVoiceId('vivi');
    final s = statusOf(taskWith(doc));
    expect(s.stage, contains('没挑镜头'));
    expect(s.next, contains('--line 2'),
        reason: '第 1 行已经挑过了，接着干该从第 2 行开始');
  });

  test('每一步的完成情况都要报，不是只报下一步', () {
    final doc = ScriptDoc([ScriptLine.create(text: '一').withVoiceover(vo('一'))])
        .withDefaultVoiceId('vivi');
    final steps = statusOf(taskWith(doc)).steps.map((s) => s.step).toList();
    expect(steps, containsAll(['台词', '本片音色', '配音', '挑镜头', '配乐', '导出']),
        reason: '人要能一眼看出「哪几步已经做完了」——'
            '不然他会怀疑是不是白干了，或者重复去干');
  });

  test('报出最后改动时间——人可能在你不在时动过手', () {
    final doc = ScriptDoc([ScriptLine.create(text: '一')]);
    final json = statusOf(taskWith(doc)).toJson();
    expect(json['updatedAt'], isNotNull,
        reason: '拿它和自己上次操作的时间比一比，对不上就先看清人改了什么，'
            '别直接覆盖');
  });
}
