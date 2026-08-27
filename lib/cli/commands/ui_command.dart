import 'dart:io';

import '../../core/storage/agent_request.dart';
import '../../core/storage/agent_presence.dart';
import '../../core/storage/ui_action.dart';
import '../agent_stage.dart';
import '../cli_output.dart';
import 'open_command.dart' show defaultAppPath;

/// `ishkafel ui new-task --mode script --tag-groups 1261` ——
/// **让界面当着人的面新建任务**。
///
/// 和 `script new` / `blank create` 的区别不是结果，是**过程**：
/// 那两条在后台把任务建好，界面一动不动；这一条会把软件拉起来、
/// 真的弹出新建向导、真的把来源和标签组填上、真的点「创建」。
///
/// 为什么值得单独有一条：严格交付的活儿，人要看得见每一步才敢信。
/// 前面走错一两步，后面差很远——只有当着人的面稳稳跑过很多次，
/// 人才会放心切到静默模式。人不在场时用 `script new` 就好，那条更快。
Future<int> runUiCommand({
  required List<String> rest,
  required Directory dataDir,
  String? mode,
  String? file,
  String? tagGroups,
  String holder = 'Agent',
  Future<ProcessResult> Function(String, List<String>)? run,
  Map<String, String>? env,
  Duration waitForUi = const Duration(seconds: 90),
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty || rest.first != 'new-task') {
    sink.writeln('用法：ishkafel ui new-task --mode <script|renew|blank> '
        '--tag-groups <id,id> [--file <原片>]');
    return exitBadUsage;
  }

  final parsed = WizardMode.parse(mode);
  if (parsed == null) {
    sink.writeln('--mode 要是 script / renew / blank 之一：\n'
        '  script  从台词造一条新片（不需要原片）\n'
        '  renew   拿一条现成的片子换画面（要 --file）\n'
        '  blank   拼画面、没有台词与配音');
    return exitBadUsage;
  }
  final ids = <int>[
    for (final piece in (tagGroups ?? '').split(','))
      ?int.tryParse(piece.trim()),
  ];
  // 先在本地拦一道：让人看着向导弹出来又因为参数不对关掉，比不弹更糟
  final issues =
      validateWizardFill(mode: parsed, filePath: file, tagGroupIds: ids);
  if (issues.isNotEmpty) {
    for (final i in issues) {
      sink.writeln('· $i');
    }
    return exitBadUsage;
  }

  // 界面没开就先拉起来——这条命令的意义就是让人看见
  final appPath = (env ?? Platform.environment)['ISHKAFEL_APP'] ?? defaultAppPath;
  final exec = run ?? Process.run;
  final launched = await exec('open', ['-a', appPath]);
  if (launched.exitCode != 0) {
    sink.writeln('打不开 app（$appPath）：${'${launched.stderr}'.trim()}');
    return exitEnv;
  }

  final id = writeAgentRequest(
    dataDir: dataDir,
    taskId: globalPresenceSlot,
    kind: UiAction.wizardOpen.wire,
    payload: {
      'mode': parsed.wire,
      if (file != null) 'filePath': file,
      'tagGroupIds': ids,
    },
  );
  sink.writeln('已让界面打开新建任务向导，正在等它建完…');
  final result = await waitForAgentRequest(
      dataDir: dataDir, taskId: globalPresenceSlot, id: id, timeout: waitForUi);
  if (result == null) {
    // 这里超时是**真失败**：活儿没干。报成功的话人会以为任务建好了
    sink.writeln('界面没有回应（等了 ${waitForUi.inSeconds} 秒）。'
        '可能它没开、或者停在别的页面上——让用户看一眼');
    return exitEnv;
  }
  if (!result.ok) {
    sink.writeln('没有建成：${result.message}');
    return exitFailed;
  }
  emitJson({'ok': true, 'via': 'ui', 'message': result.message}, out: out);
  return 0;
}
