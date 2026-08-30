import 'dart:io';

import '../../core/storage/agent_request.dart';
import '../../core/storage/file_task_repository.dart';
import '../../core/storage/agent_presence.dart';
import '../../core/storage/ui_action.dart';
import '../cli_output.dart';
import '../app_locator.dart';

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

  /// 任务名。不给就用软件的默认命名（「脚本 08-27 20:57」这种）
  String? name,
  String? holder,
  Future<ProcessResult> Function(String, List<String>)? run,
  Map<String, String>? env,

  /// 测试注入：app 在不在。真机走默认（看目录存不存在）
  bool Function(String path)? appExists,
  Duration waitForUi = const Duration(seconds: 90),

  /// 冷启动后等多久再下单。界面那头也有一道同样的缓冲
  Duration coldStartWait = const Duration(seconds: 6),
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty || rest.first != 'new-task') {
    sink.writeln('用法：ishkafel ui new-task --mode <replace|blank|script> '
        '--tag-groups <id,id> [--file <原片>]');
    return exitBadUsage;
  }

  final parsed = WizardMode.parse(mode);
  if (parsed == null) {
    // 报错里的词必须是现在的词：人照着报错去敲，写出来的就是这几个。
    // 这儿曾经还写着废弃的 renew，而手册早改成 replace 了
    sink.writeln('--mode 要是 replace / blank / script 之一：\n'
        '  replace  替换裂变，拿一条现成的片子换画面（要 --file）\n'
        '  blank    替换裂变但不用原片：拼画面、没有台词与配音\n'
        '  script   脚本成片，从台词造一条新片');
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
  final exec = run ?? Process.run;
  final appPath = resolveAppPath(env: env, exists: appExists);
  // 冷启动的话，界面要几秒才起得来。先探一眼它在不在，好决定等多久
  final wasRunning =
      appPath != null && await _appIsRunning(exec, appPath);
  final failure = await launchApp(run: exec, env: env, exists: appExists);
  if (failure != null) {
    sink.writeln(failure);
    return exitEnv;
  }
  if (!wasRunning) {
    // 刚拉起来的软件不能立刻使唤：界面 1.5 秒就能接单，但那时播放器的
    // 底层还没初始化完，建完任务一进编导台就会整个 abort（真机撞过两次）。
    // 界面那头也有一道缓冲，这里是第二道——两边都等，别指望其中一边
    sink.writeln('软件刚启动，等它就绪…');
    await Future<void>.delayed(coldStartWait);
  }

  final id = writeAgentRequest(
    dataDir: dataDir,
    taskId: globalPresenceSlot,
    kind: UiAction.wizardOpen.wire,
    payload: {
      'mode': parsed.wire,
      'filePath': ?file,
      if ((name ?? '').trim().isNotEmpty) 'name': name!.trim(),
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
  // 界面把它**真正建出来的那条**回传了，不再去任务库里翻「最新的那条」猜。
  // 猜的后果真机上撞到过：授权框挡住创建、任务压根没建成，
  // 猜出来的是上一次的任务，还报「已经建好了」
  final newId = '${result.payload['taskId'] ?? ''}';
  if (newId.isEmpty) {
    sink.writeln('界面说建好了，却没报出是哪一条任务。'
        '用 ishkafel tasks 看一眼，别照着猜的 id 往下走');
    return exitFailed;
  }
  final created = await FileTaskRepository(dataDir).findById(newId);
  final kind = '${result.payload['kind'] ?? ''}';
  emitJson({
    'ok': true,
    'via': 'ui',
    'message': result.message,
    'id': newId,
    if (created?.seq != null) 'seq': created!.seq,
    if (created != null) 'name': created.name,
    'kind': kind,
    // **下一步要跟着任务类型走**：以前恒定给 script show，
    // 而替换裂变任务照着跑会被 CLI 自己拒绝（验收 Agent 撞到）
    'next': switch (kind) {
      'script' => 'ishkafel script show $newId',
      'blank' => 'ishkafel blank tags $newId --unit 0 --tags <标签>',
      _ => 'ishkafel task $newId',
    },
  }, out: out);
  return 0;
}

/// app 是不是已经在跑。冷启动和已运行要等的时间差很多
Future<bool> _appIsRunning(
    Future<ProcessResult> Function(String, List<String>) exec,
    String appPath) async {
  try {
    final r = await exec('pgrep', ['-f', '$appPath/Contents/MacOS/']);
    return r.exitCode == 0 && '${r.stdout}'.trim().isNotEmpty;
  } catch (_) {
    return false;
  }
}
