import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/agent_skill/agent_skill_doc.dart';
import 'package:ishkafel/core/storage/ui_action.dart';

/// **Agent 要能把界面挪到该在的地方，两个方向都要有。**
///
/// 这个文件原名 `agent_has_unlock_path_test`：那时它守的是「Agent 永远有
/// 一条解锁的路」——`ui new-task` 建完任务界面就停在那条任务上占着写锁，
/// 而下一步非写它不可，于是得有办法把界面支开。2026-09-18 整套锁删掉之后
/// 「解锁」这件事不存在了，那几条断言也没有对象了。
///
/// 但底下这两样留了下来，而且和锁无关：
///
/// 1. **支得开**（`ui tasks` → 界面退回列表）：人要看别的了，Agent 得能
///    把它带回列表。加了动作没人接的话，Agent 只会等到超时
/// 2. **叫得回**（`ui open <任务>`）：只有支开的命令、没有叫回来的命令，
///    一旦支开就再也回不到现场——后面几十步人一格都看不见。真机上撞过
void main() {
  test('界面认得「回任务列表」这个动作', () {
    expect(UiAction.parse('tasks.open'), UiAction.tasksOpen);
  });

  test('列表页真的处理它——光有枚举等于没有', () {
    final src =
        File('lib/features/tasks/task_list_page.dart').readAsStringSync();
    expect(src, contains('UiAction.tasksOpen'),
        reason: '加了动作没人接，Agent 只会等到超时');
    expect(src, contains('popUntil'),
        reason: '要真的把压在列表上面的页面弹掉，不然人看到的还是原来那一页');
  });

  test('命令行有入口', () {
    final src = File('lib/cli/commands/ui_command.dart').readAsStringSync();
    expect(src, contains("rest.first == 'tasks'"),
        reason: 'ui tasks 是 Agent 敲的那一下');
  });

  test('手册要给出把界面叫回现场的入口', () {
    expect(agentSkillMarkdown, contains('ishkafel ui open'),
        reason: '只有把界面支开的命令、没有叫回来的命令，Agent 一旦支开'
            '就再也回不到现场——后面几十步人一格都看不见');
  });
}
