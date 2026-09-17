import 'dart:convert';
import 'dart:io';

import '../../core/miaoa/miaoa_tag_service.dart';
import '../../core/storage/agent_request.dart';
import '../../core/storage/file_task_repository.dart';
import '../../core/storage/agent_presence.dart';
import '../../core/storage/task_seq.dart';
import '../../core/storage/ui_action.dart';
import '../../core/storage/ui_wake.dart';
import '../../core/storage/ui_where.dart';
import '../cli_output.dart';
import '../app_locator.dart';
import 'blank_command.dart' show runBlankCommand;
import 'import_command.dart' show runImportCommand;
import 'script_run_command.dart' show runScriptNewCommand;

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

  /// `ui open` 要去哪个模块：`director` / `workbench` / `review`。
  /// 不给就按任务类型选（脚本成片进编导台，其余进工作台）
  String? module,
  String? holder,
  Future<ProcessResult> Function(String, List<String>)? run,
  Map<String, String>? env,

  /// 测试注入：app 在不在。真机走默认（看目录存不存在）
  bool Function(String path)? appExists,

  /// 委派是首选路径，不是必经之路——秒级兜底，不是 90 秒必经之路
  /// （见 `delegate.dart`）。界面没跟上就自己建/自己去，不等它
  Duration waitForUi = const Duration(seconds: 2),

  /// 冷启动后等多久再下单。界面那头也有一道同样的缓冲
  Duration coldStartWait = const Duration(seconds: 6),

  /// 测试注入：新建兜底（`_createTaskMyself`）用的标签组查询假实现
  MiaoaTagService? tagService,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  const subs = ['new-task', 'tasks', 'open'];
  if (rest.isEmpty || !subs.contains(rest.first)) {
    sink.writeln('用法：\n'
        '  ishkafel ui new-task --mode <replace|blank|script> '
        '--tag-groups <id,id> [--file <原片>]\n'
        '  ishkafel ui open <任务> [--module director|workbench|review]\n'
        '      把界面叫到这条任务上。**可视模式下每一步开工前都该在现场**\n'
        '  ishkafel ui tasks\n'
        '      把界面支开、退回任务列表。可视模式下一般用不着：**人开着那一页\n'
        '      从来不会挡住任何写操作**，不需要你先支开它。\n'
        '      支开了就等于关掉了可视化现场，要再用 ui open 才叫得回来');
    return exitBadUsage;
  }
  if (rest.first == 'open') {
    return _openTaskPage(
      rest: rest.sublist(1),
      dataDir: dataDir,
      module: module,
      run: run,
      env: env,
      appExists: appExists,
      waitForUi: waitForUi,
      out: out,
      err: err,
    );
  }
  if (rest.first == 'tasks') {
    return _backToTaskList(
      dataDir: dataDir,
      run: run,
      env: env,
      appExists: appExists,
      waitForUi: waitForUi,
      out: out,
      err: err,
    );
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
    // 超时不再是失败：委派是首选路径，不是必经之路（见 delegate.dart）。
    // 界面没跟上——没开、或者停在别的页面收不到这个请求——就自己建，
    // 三种模式都有现成的、不经界面就能建任务的 CLI 命令
    sink.writeln('界面没接这一单（等了 ${waitForUi.inSeconds} 秒），我自己建。');
    return _createTaskMyself(
      mode: parsed,
      name: name,
      file: file,
      tagGroups: tagGroups,
      dataDir: dataDir,
      tagService: tagService,
      sink: sink,
      out: out,
      err: err,
    );
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
    //
    // 以前这里还带一句「先 ishkafel ui tasks 退回列表再写」——
    // 锁删掉之后这条往返彻底多余了：写操作从来不会因为人开着那一页
    // 而写不进去，不需要 Agent 先手动把界面支开
    'next': switch (kind) {
      'script' => 'ishkafel script extract $newId <参考片>',
      'blank' => 'ishkafel blank tags $newId --unit 0 --tags <标签>',
      _ => 'ishkafel task $newId',
    },
  }, out: out);
  return 0;
}

/// 界面没跟上（没开、或者停在别的页面收不到这个请求）：**不是失败**。
/// 三种模式都有现成的、不经界面就能建任务的 CLI 命令——直接调它们，
/// 别让 Agent 因为可视化掉线就建不成任务。
///
/// `replace`（有原片）用 `import`：它不会像向导那样建完顺手把分析跑起来
/// ——CLI 这条线一贯把「建」和「分析」拆成两步，Agent 自己控制每一步。
/// 这个差别**必须说清楚**，不然人会以为这条任务已经在分析了
/// （不静默降级：差别可以有，但不能闷着）
Future<int> _createTaskMyself({
  required WizardMode mode,
  required String? name,
  required String? file,
  required String? tagGroups,
  required Directory dataDir,
  required MiaoaTagService? tagService,
  required StringSink sink,
  required StringSink? out,
  required StringSink? err,
}) async {
  final captured = StringBuffer();
  final code = await switch (mode) {
    WizardMode.script => runScriptNewCommand(
        rest: [
          (name ?? '').trim().isNotEmpty
              ? name!.trim()
              : '脚本 ${DateTime.now().toString().substring(5, 16)}',
        ],
        dataDir: dataDir,
        tagGroups: tagGroups,
        tagService: tagService,
        out: captured,
        err: err,
      ),
    WizardMode.blank => runBlankCommand(
        rest: const ['create'],
        dataDir: dataDir,
        name: name,
        tagGroups: tagGroups,
        tagService: tagService,
        out: captured,
        err: err,
      ),
    // validateWizardFill 已经在前面确认过 replace 模式一定给了 --file
    WizardMode.replace => runImportCommand(
        rest: [file!],
        dataDir: dataDir,
        tagGroups: tagGroups,
        tagService: tagService,
        out: captured,
        err: err,
      ),
  };
  if (code != 0) return code; // 子命令自己已经把原因写到 err 了，原样透传

  final made = jsonDecode(captured.toString().trim()) as Map<String, dynamic>;
  final newId = '${made['taskId'] ?? made['id'] ?? ''}';
  emitJson({
    'ok': true,
    'via': 'agent',
    'landed': false,
    'id': newId,
    if (made['seq'] != null) 'seq': made['seq'],
    if (made['name'] != null) 'name': made['name'],
    'kind': mode.wire,
    'message': '界面没跟上，我自己建的',
    if (mode == WizardMode.replace)
      'note': '界面没跟上，我用 import 自己建的——'
          '和界面建的区别是没有自动开始分析',
    'next': switch (mode) {
      WizardMode.script => 'ishkafel script extract $newId <参考片>',
      WizardMode.blank => 'ishkafel blank tags $newId --unit 0 --tags <标签>',
      WizardMode.replace => 'ishkafel analyze $newId',
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


/// `ishkafel ui tasks` —— 让界面退回任务列表。
///
/// **这条命令曾经是「解锁的唯一出路」**：`ui new-task` 建完任务后界面停在
/// 那条任务上，占着写锁，于是「建完立刻干活」这条最自然的路走不通，Agent
/// 只能先把界面支开。锁没了，这条理由也随之消失——现在它就只是一句
/// 「回列表看看」，想用就用，不用也不会挡住任何事。
Future<int> _backToTaskList({
  required Directory dataDir,
  Future<ProcessResult> Function(String, List<String>)? run,
  Map<String, String>? env,
  bool Function(String path)? appExists,
  Duration waitForUi = const Duration(seconds: 2),
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  final failure =
      await launchApp(run: run ?? Process.run, env: env, exists: appExists);
  if (failure != null) {
    sink.writeln(failure);
    return exitEnv;
  }
  final id = writeAgentRequest(
    dataDir: dataDir,
    taskId: globalPresenceSlot,
    kind: UiAction.tasksOpen.wire,
    payload: const {},
  );
  final result = await waitForAgentRequest(
      dataDir: dataDir, taskId: globalPresenceSlot, id: id, timeout: waitForUi);
  if (result == null) {
    // 超时不是失败：它多半没开。而且退不退回列表本来就不影响任何写操作
    sink.writeln('界面没接这一单（等了 ${waitForUi.inSeconds} 秒），我没等它——'
        '它可能没开，也可能没在监听这个请求。'
        '这不影响任何事，写操作照样进行');
    emitJson({
      'ok': true,
      'via': 'agent',
      'landed': false,
      'message': '界面没接这一单，没等它退回列表',
    }, out: out);
    return 0;
  }
  if (!result.ok) {
    sink.writeln('退不回列表：${result.message}');
    return exitFailed;
  }
  emitJson({'ok': true, 'via': 'ui', 'message': result.message}, out: out);
  return 0;
}


/// `ishkafel ui open <任务> [--module …]` —— **把界面叫到现场**。
///
/// 可视模式此前只有出口没有入口：[UiAction.tasksOpen] 能把界面支开，
/// 却没有任何办法把它叫回来。真机上 Agent 为了拿写锁调了 `ui tasks`，
/// 界面退到任务列表，此后二十句配音全程在列表页上以文字滚过——播报没
/// 说谎，可视化却结束了，而且回不去。产品负责人的话：「它并不判断当前
/// 是否是它执行的那个页面，这样的话可视化的意义就没有了。」
///
/// 各条命令自己也会在每一步开工前确认现场（见 `AgentStage`），这条命令
/// 是给 Agent 的显式入口：接着干之前先把人带回该看的那一页。
Future<int> _openTaskPage({
  required List<String> rest,
  required Directory dataDir,
  String? module,
  Future<ProcessResult> Function(String, List<String>)? run,
  Map<String, String>? env,
  bool Function(String path)? appExists,
  Duration waitForUi = const Duration(seconds: 2),
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('要指定任务：ishkafel ui open <任务 id>');
    return exitBadUsage;
  }
  const modules = ['director', 'workbench', 'review'];
  if (module != null && !modules.contains(module)) {
    // 写错了就点名。默默去个别的地方，人对着不相干的页面等半天
    sink.writeln('--module 要是 ${modules.join(' / ')} 之一');
    return exitBadUsage;
  }
  final task = await resolveTaskRef(FileTaskRepository(dataDir), rest.first);
  if (task == null) {
    sink.writeln('没有这个任务：${rest.first}');
    return exitNotFound;
  }
  final target = module ?? (task.isScript ? 'director' : 'workbench');
  // 已经在这一页就别再唤醒：唤醒会把页面关掉重开，滚动位置、展开的镜头
  // 全丢，人看到的是画面弹回第一行
  if (readUiWhere(dataDir)?.isOn(module: target, taskId: task.id) == true) {
    emitJson({'ok': true, 'already': true, 'module': target, 'task': task.id},
        out: out);
    return 0;
  }
  final failure =
      await launchApp(run: run ?? Process.run, env: env, exists: appExists);
  if (failure != null) {
    sink.writeln(failure);
    return exitEnv;
  }
  writeUiWake(dataDir, task.id, review: target == 'review', module: target);
  // 等它真的到位再返回：命令一返回就接着干活的话，头几步又落在空场上
  final deadline = DateTime.now().add(waitForUi);
  while (DateTime.now().isBefore(deadline)) {
    if (readUiWhere(dataDir)?.isOn(module: target, taskId: task.id) == true) {
      emitJson({'ok': true, 'module': target, 'task': task.id}, out: out);
      return 0;
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  // 没等到不算失败：软件可能正在冷启动，唤醒文件躺在那儿，它起来就会落位
  sink.writeln('界面还没落到「$target」（等了 ${waitForUi.inSeconds} 秒）。'
      '唤醒已经写下了，软件起来就会过去。');
  emitJson({'ok': true, 'module': target, 'task': task.id, 'landed': false},
      out: out);
  return 0;
}
