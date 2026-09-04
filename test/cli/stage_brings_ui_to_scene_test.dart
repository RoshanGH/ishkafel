import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/agent_stage.dart';
import 'package:ishkafel/core/storage/agent_presence.dart';
import 'package:ishkafel/core/storage/ui_where.dart';

/// **每走一步都先确认现场**——界面在哪、这一步该在哪一页看。
///
/// 真机事故：脚本成片的配音在横幅上一句句念「正在给第 10 句配音（10/20）」，
/// 界面却停在任务列表，二十句没有一格出现在屏幕上。播报没说谎，可视化却
/// 没发生。产品负责人的话：「它并不判断当前是否是它执行的那个页面，
/// 这样的话可视化的意义就没有了。」
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('stage'));
  tearDown(() => dir.deleteSync(recursive: true));

  File wakeFile() => File('${dir.path}/ui_wake.json');
  void uiIsOn(String module, {String? task = 't1'}) =>
      writeUiWhere(dir, module: module, taskId: task);

  AgentStage stage({String taskId = 't1'}) => AgentStage(
        mode: AgentStageMode.visual,
        dataDir: dir,
        taskId: taskId,
        stepTimeout: const Duration(milliseconds: 1),
        run: (_, _) async => ProcessResult(0, 0, '', ''),
        appExists: (_) => true,
      );

  test('界面不在这一页：把它带过去', () async {
    uiIsOn('tasks', task: null);
    await stage().show('挑镜头',
        focus: const AgentFocus(module: 'director', lineIndex: 3));
    expect(wakeFile().existsSync(), isTrue,
        reason: '人停在任务列表，这一步该在编导台看——不带过去就等于没有可视化');
  });

  test('界面已经在这一页：什么都不做，别把人拽来拽去', () async {
    uiIsOn('director');
    final s = stage();
    await s.show('挑镜头', focus: const AgentFocus(module: 'director'));
    expect(wakeFile().existsSync(), isFalse,
        reason: '已经在现场还发唤醒，会把编导台销毁重建、滚动位置全丢');
  });

  test('人中途退出去了：下一步再把它叫回来（不只第一步检查）', () async {
    uiIsOn('director');
    final s = stage();
    await s.show('第一步', focus: const AgentFocus(module: 'director'));
    expect(wakeFile().existsSync(), isFalse);

    uiIsOn('tasks', task: null); // 人自己退回了列表
    await s.show('第二步', focus: const AgentFocus(module: 'director'));
    expect(wakeFile().existsSync(), isTrue,
        reason: '被打断后接着干，也要重新确认现场——包括第一次以外的每一次');
  });

  test('界面停在另一条任务上：也要带过来', () async {
    writeUiWhere(dir, module: 'director', taskId: '别的任务');
    await stage().show('挑镜头', focus: const AgentFocus(module: 'director'));
    expect(wakeFile().existsSync(), isTrue);
  });

  test('界面根本没开：照样写唤醒，它启动后就能落到位', () async {
    await stage().show('挑镜头', focus: const AgentFocus(module: 'director'));
    expect(wakeFile().existsSync(), isTrue);
  });

  test('静默模式不碰界面', () async {
    final s = AgentStage(
        mode: AgentStageMode.silent, dataDir: dir, taskId: 't1');
    await s.show('挑镜头', focus: const AgentFocus(module: 'director'));
    expect(wakeFile().existsSync(), isFalse);
  });
}
