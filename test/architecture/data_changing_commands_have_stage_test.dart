import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **凡是会改数据的命令，都要有舞台。**
///
/// 没有舞台 = 可视模式下什么都不会发生：界面不跟过来、人看不见它改了哪一行。
/// 产品负责人从头核过一遍命令清单，问的就是这句话——「你确定全部改完了？」
/// 当时的答案是没有：`script voice-file`、`subtitle`、`bgm`、`analyze`、
/// `apply segment/tags` 五处都还在闷头改数据。
///
/// 下面这份白名单是**只读或管理类**——它们不动任何进成片的东西。
/// 往里加名字之前先问一句：它改的东西会不会出现在成片里？会就不该在这儿。
void main() {
  const readOnlyOrAdmin = {
    // 只读
    'runTasksCommand', 'runTaskCommand', 'runStatusCommand', 'runTodoCommand',
    'runDoctorCommand', 'runTagGroupsCommand', 'runPeekCommand',
    'runScriptPeekCommand', 'runScriptFramesCommand',
    'runScriptBgmCandidatesCommand',
    // 管理与导航（不改成片内容）
    'runCleanCommand', 'runSkillCommand', 'runOpenCommand', 'runUiCommand',
    'runTaskDeleteCommand', 'runTaskRenameCommand',
    // 分发器：真正干活的子命令自己有舞台
    'runVoiceCommand',
    // 建任务：可视模式下走 ui new-task（界面当着人的面建）
    'runBlankCommand', 'runScriptNewCommand',
    // 提交方案走委派：界面自己动手，人本来就看得见
    // （委派前会先把界面叫回这条任务，见 _applyPlansViaUi）
    'runApplyCommand',
  };

  test('会改数据的命令都要有 AgentStage', () {
    final missing = <String>[];
    for (final f in Directory('lib/cli/commands')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final src = f.readAsStringSync();
      for (final m
          in RegExp(r'\nFuture<int> (run\w+Command)\(').allMatches(src)) {
        final name = m.group(1)!;
        if (readOnlyOrAdmin.contains(name)) continue;
        var body = src.substring(m.end);
        final next = RegExp(r'\nFuture<int> run\w+Command\(').firstMatch(body);
        if (next != null) body = body.substring(0, next.start);
        if (!body.contains('AgentStage(')) {
          missing.add('${f.uri.pathSegments.last} → $name');
        }
      }
    }
    expect(missing, isEmpty,
        reason: '这些命令会改数据却没有舞台——可视模式下界面不会跟过来，'
            '人看不见它动了什么：\n${missing.join('\n')}\n'
            '要么接上 AgentStage，要么（确认它只读之后）加进白名单');
  });
}
