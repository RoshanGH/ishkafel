import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/storage/agent_presence.dart';
import 'package:path/path.dart' as p;

/// Agent 干活的时候，人在旁边看得懂它在动什么——这是用户明确要的：
/// 「它选中第 10 行，就把第 10 行放到界面中间；它去调某一镜的时长，
/// 那个面板就打开，跟人自己点开时一样」。
/// 光看数据变化推不出「它正在看哪儿」，所以焦点必须由它主动上报。
void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('presence'));
  tearDown(() => dir.delete(recursive: true));

  test('写一次读一次：谁在、在干什么、焦点落在哪', () {
    writeAgentPresence(
      dataDir: dir,
      taskId: 't1',
      presence: AgentPresence(
        holder: 'Agent',
        at: DateTime.now(),
        action: '正在给第 10 句挑镜头',
        focus: const AgentFocus(
            lineIndex: 9, shotIndex: 2, panel: AgentPanel.shot),
      ),
    );

    final back = readAgentPresence(dataDir: dir, taskId: 't1')!;
    expect(back.holder, 'Agent');
    expect(back.action, '正在给第 10 句挑镜头');
    expect(back.focus!.lineIndex, 9);
    expect(back.focus!.shotIndex, 2);
    expect(back.focus!.panel, AgentPanel.shot);
  });

  test('心跳停了就当它不在——Agent 崩掉不能让界面一直锁着', () {
    writeAgentPresence(
      dataDir: dir,
      taskId: 't1',
      presence: AgentPresence(
        holder: 'Agent',
        at: DateTime.now().subtract(const Duration(seconds: 90)),
        action: '挑镜头',
      ),
    );
    expect(readAgentPresence(dataDir: dir, taskId: 't1'), isNull,
        reason: '60 秒没心跳就视为不在场，与任务锁同一条规矩');
  });

  test('没有焦点也合法：它可能在读、在想，还没动到具体某一行', () {
    writeAgentPresence(
      dataDir: dir,
      taskId: 't1',
      presence: AgentPresence(
          holder: 'Agent', at: DateTime.now(), action: '正在通读整个脚本'),
    );
    final back = readAgentPresence(dataDir: dir, taskId: 't1')!;
    expect(back.focus, isNull);
    expect(back.action, '正在通读整个脚本');
  });

  test('文件坏了不炸——读不懂就当没人在，不能把界面卡死', () {
    final f = File(p.join(dir.path, 'presence', 't1.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{这不是 json');
    expect(f.existsSync(), isTrue);
    expect(readAgentPresence(dataDir: dir, taskId: 't1'), isNull);
  });

  test('清场：干完活要把在场状态撤掉，别让界面以为它还在', () {
    writeAgentPresence(
      dataDir: dir,
      taskId: 't1',
      presence: AgentPresence(
          holder: 'Agent', at: DateTime.now(), action: '挑镜头'),
    );
    clearAgentPresence(dataDir: dir, taskId: 't1');
    expect(readAgentPresence(dataDir: dir, taskId: 't1'), isNull);
  });

  test('json 往返一字不差（焦点面板也要认得回来）', () {
    for (final panel in AgentPanel.values) {
      writeAgentPresence(
        dataDir: dir,
        taskId: 't1',
        presence: AgentPresence(
          holder: 'Agent',
          at: DateTime.now(),
          action: '测试 $panel',
          focus: AgentFocus(lineIndex: 3, panel: panel),
        ),
      );
      expect(readAgentPresence(dataDir: dir, taskId: 't1')!.focus!.panel,
          panel);
    }
  });
}
