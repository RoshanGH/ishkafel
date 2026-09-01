import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/agent_skill/agent_skill_doc.dart';
import 'package:ishkafel/core/storage/ui_action.dart';

/// 可视模式下 Agent 必须**永远有一条解锁的路**。
///
/// 死结长这样：`ui new-task` 建完任务，界面就停在那条任务上占着写锁，
/// 而下一步（脚本成片是 `script extract`，替换裂变是 `analyze`）非写它
/// 不可——于是「建完立刻干活」这条最自然的路走不通。
///
/// 以前的出路是 `open <另一条任务>` 把界面支开。那条路有个隐含前提：
/// **恰好还有第二条任务**。验收 Agent 就是这么绕的；等它把老任务删光，
/// 就彻底卡死了——一条任务都没有的新用户，第一次用就会撞上。
void main() {
  test('界面认得「回任务列表」这个动作', () {
    expect(UiAction.parse('tasks.open'), UiAction.tasksOpen,
        reason: '这是唯一不依赖「还有第二条任务」的解锁出路');
  });

  test('列表页真的处理它——光有枚举等于没有', () {
    final src =
        File('lib/features/tasks/task_list_page.dart').readAsStringSync();
    expect(src, contains('UiAction.tasksOpen'),
        reason: '加了动作没人接，Agent 只会等到超时');
    expect(src, contains('popUntil'),
        reason: '要真的把压在列表上面的页面弹掉，那些页面退出才会松锁');
  });

  test('命令行有入口', () {
    final src = File('lib/cli/commands/ui_command.dart').readAsStringSync();
    expect(src, contains("rest.first == 'tasks'"),
        reason: 'ui tasks 是 Agent 敲的那一下');
  });

  test('手册要写明撞锁是常态、不用自己去腾锁', () {
    expect(agentSkillMarkdown, contains('自动请界面让位'),
        reason: '手册不说的话，Agent 撞上「正在操作这个任务」只能自己瞎试——'
            '真机上它试过「打开另一条任务」（只有一条任务时是死的），'
            '也试过 ui tasks 把界面支开（可视化现场就此关掉）');
  });

  test('手册要给出把界面叫回现场的入口', () {
    expect(agentSkillMarkdown, contains('ishkafel ui open'),
        reason: '只有把界面支开的命令、没有叫回来的命令，Agent 一旦支开'
            '就再也回不到现场——后面几十步人一格都看不见');
  });
}
