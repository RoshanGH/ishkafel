import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **同一条任务不能有两个各自写盘的写入方。**
///
/// 任务是整份对象存盘，没有字段级合并——后写的那个会把先写的改动整片盖掉，
/// 而且不报错。这个形状在这个项目里已经撞见过五次（管线打标 vs 工作台编辑、
/// 审核页 vs 工作台、设置页三层缓存、按下标记的三份数据、Agent 的旧快照）。
///
/// 锁删掉之后两边真的会同时写，所以从这里开始**只允许一个写入口**：
/// `TaskMutation`。它落盘前重读、落盘前回读比对版本（被抢写就拿新数据重跑一遍）、
/// 落盘后记日志。
///
/// **注意它做到的是什么**：把「拿旧快照整份写回」的窗口从「一次改动的整个思考
/// 时间」压到「一次同步回调」，并在这个窗口内被抢写时重跑一轮——**不是把并发
/// 写变成零**。写清楚是因为承重件的文档比代码强，将来的人会照着它设计更激进的写法。
void main() {
  /// 白名单一：这几个文件是写入口自己——整份豁免
  const allowedFiles = {
    'lib/core/storage/task_mutation.dart', // 写入口本人
    'lib/core/storage/file_task_repository.dart',
    'lib/core/storage/task_repository.dart',
  };

  /// 白名单二：**建新任务**的那一处，没有「已存在的任务」可重读，
  /// 结构上就不是 TaskMutation 的候选（`blank create` / `task-copy` /
  /// `script new` 建的都是带新 id 的全新 `RenewTask`）。
  ///
  /// 只许放**建新任务**的那一处，narrow 到「文件 + 函数」，不是整个文件——
  /// 以后有人往这个函数里加一处「改已存在任务」的写入，这条测试必须还能
  /// 抓住它（新写入不在下面这份函数名单里，照样会被扫到）。
  const allowedNewTaskCreation = {
    'lib/cli/commands/blank_command.dart': {'_create'},
    'lib/cli/commands/tasks_command.dart': {'runTaskCopyCommand'},
    'lib/cli/commands/script_run_command.dart': {'runScriptNewCommand'},
    // 界面这一侧建新任务的三条路（新建向导的「空白拼片」「脚本成片」
    // 与「导入视频」）——和上面三条 CLI 命令是同一件事的两个入口
    'lib/features/import_flow/import_service.dart': {
      'createBlank',
      'createScript',
      'importLocalFile',
    },
    // 复制任务：`TaskCopier.duplicate` 产出的是带新 id 的全新任务，
    // 和 CLI 的 `task-copy` 同一件事
    'lib/features/tasks/task_list_controller.dart': {'copyTask'},
  };

  /// 白名单三：**给老任务补短编号**那一处。
  ///
  /// 它确实是在改已存在的任务，但改的是「#12」这个只给人念的显示号，
  /// 且是一次性的存档补丁（`seq` 字段是后加的，老存档没有）。走
  /// `TaskMutation` 会有一个说不通的副作用：`apply` 统一把 `updatedAt`
  /// 推到当下，于是升级后第一次打开，**所有老任务一起跳到列表最前面**
  /// （列表按 updatedAt 倒序），人看到的是「我的任务全乱了」。
  ///
  /// 为一个显示号付这个代价不值。同样 narrow 到「文件 + 函数」。
  const allowedSeqBackfill = {
    'lib/core/storage/task_seq.dart': {'ensureTaskSeqs'},
  };

  /// 扫描范围分两步走：Task 6 先管住 CLI，Task 7 再扩到整个 lib。
  /// 一上来就扫全 lib 的话，Task 6 做完它照样是红的（界面还没迁），
  /// 那这条测试就没法当 Task 6 的验收门。**Task 7 已经扩完**。
  const scanRoot = 'lib';

  test('除了 TaskMutation，没有别的地方直接 save 已存在的任务', () {
    final offenders = <String>[];
    for (final f in Directory(scanRoot)
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final rel = f.path.replaceFirst('${Directory.current.path}/', '');
      if (allowedFiles.contains(rel)) continue;
      final allowedFns = {
        ...?allowedNewTaskCreation[rel],
        ...?allowedSeqBackfill[rel],
      };
      final content = f.readAsStringSync();
      final lines = content.split('\n');

      // 谁被声明/赋值成任务仓库类型，就认它是仓库接收者——不管变量叫
      // repo 还是 r、store、db。名字判据（下面 _looksLikeRepoName）
      // 单独也算数，两个判据取「或」：一处漏了类型声明（比如函数参数
      // 用了别的写法），名字判据兜底；一处起了个不带 repo 字样的名字，
      // 类型判据兜底
      final typedRepoNames = {
        for (final m in RegExp(
                r'\b(?:Task[A-Za-z]*Repository|FileTaskRepository)\s+(\w+)\b')
            .allMatches(content))
          m.group(1)!,
        for (final m in RegExp(
                r'\b(\w+)\s*=\s*(?:const\s+)?(?:Task[A-Za-z]*Repository|FileTaskRepository)\s*\(')
            .allMatches(content))
          m.group(1)!,
      };

      // receiver 和 .save( 之间允许任意空白（含换行）——`repository\n
      // .save(` 这种跨行写法不能漏过。整份文件文本一起匹配，不再逐行扫。
      //
      // **接收者不一定是裸标识符**：GUI 那边真实的写法是
      // `ref.read(taskRepositoryProvider).save(...)`——接收者是一整条
      // 「标识符.方法(参数)」调用链，`.save(` 前面紧挨着的是 `)` 不是
      // 变量名，旧版 `\b(\w+)\.save\(` 在这种形状上完全不匹配（2026-09-17
      // 复审指出：这会让下一个任务把 scanRoot 扩到全 lib 之后，14 处真实
      // 的界面写入点全部静悄悄放过，验收门形同虚设）。改成允许接收者是
      // 「(标识符 或 标识符(参数))」用点号串起来的一条链，`([^()]*` 不处理
      // 参数里嵌套括号——这批代码里没有这种写法，够用
      final saveCallPattern = RegExp(
          r'((?:\w+(?:\([^()]*\))?\s*\.\s*)*\w+(?:\([^()]*\))?)\s*\.\s*save\s*\(');
      for (final m in saveCallPattern.allMatches(content)) {
        final receiver = m.group(1)!;
        if (!_looksLikeRepoName(receiver) && !typedRepoNames.contains(receiver)) {
          continue;
        }
        final lineIndex = content.substring(0, m.start).split('\n').length - 1;
        final fn = _enclosingFunction(lines, lineIndex);
        if (fn != null && allowedFns.contains(fn)) continue;
        offenders.add('$rel${fn == null ? '' : ' → $fn'} → $receiver.save(');
      }
    }
    expect(offenders, isEmpty,
        reason: '这些地方绕过 TaskMutation 直接写任务——它们会拿旧快照整份'
            '写回，把别人的改动静默抹掉，而且日志里不会有这一条：\n'
            '${offenders.toSet().join('\n')}\n'
            '改成 TaskMutation(...).apply(taskId: …, op: …, edit: (fresh) => …)，'
            '注意 edit 里只能读 fresh，不许引用外层的旧 task');
  });
}

/// 只认任务仓库那一类接收者的**名字**判据——跟类型判据（见上）取「或」，
/// 不是唯一防线
bool _looksLikeRepoName(String receiver) =>
    RegExp(r'repo|repository|tasks?Repo', caseSensitive: false)
        .hasMatch(receiver);

/// 往上找最近一行**函数签名**（顶层函数或类里的方法），返回函数名；
/// 找不到给 null。
///
/// 只是个规则扫描器的启发式判断，不是真的解析 Dart AST——这份代码的
/// 函数都是「返回类型 空格 函数名 (」这个形状（`Future<int> _create(`
/// / `Future<RenewTask> createBlank({`），够用。
///
/// **必须认得类里的方法**：白名单要 narrow 到「文件 + 函数」，而界面这一侧
/// 建新任务的三处（`ImportService.createBlank` 等）全是方法，不是顶层函数。
/// 旧版只认不缩进的签名，方法一律算「找不到」，于是只能整份文件豁免——
/// 那等于以后有人往 `ImportService` 里加一处「改已存在任务」的写入，
/// 这条测试再也拦不住。
///
/// 判据是**缩进**：签名一定比它函数体里的调用浅。这一条顺带滤掉了
/// `if (…) {` / `} catch (e) {` / 多行参数列表这些干扰行（它们要么更深，
/// 要么根本不是「名字 + 左括号」的形状）。
String? _enclosingFunction(List<String> lines, int callLineIndex) {
  final callIndent = _indentOf(lines[callLineIndex]);
  final sig = RegExp(r'^\s*(?:@\w+\s+)*(?:static\s+)?'
      r'[A-Za-z_][\w<>,\.\s\?\[\]]*\s+([A-Za-z_]\w*)\s*\(');
  // 形状上撞得上签名的语句关键字，单独挡掉
  const notFunctionNames = {'if', 'for', 'while', 'switch', 'catch', 'return'};
  for (var i = callLineIndex; i >= 0 && i < lines.length; i--) {
    final line = lines[i];
    if (line.trim().isEmpty) continue;
    // 比调用还深（或一样深）的行不可能是它的签名
    if (_indentOf(line) >= callIndent) continue;
    // 多行参数列表里的一行（`void Function(Progress)? onProgress,`）形状上
    // 跟签名一模一样，会把函数名认成 `Function`。签名不会以逗号收尾
    if (line.trimRight().endsWith(',')) continue;
    final m = sig.firstMatch(line);
    if (m == null) continue;
    final name = m.group(1)!;
    if (notFunctionNames.contains(name)) continue;
    return name;
  }
  return null;
}

int _indentOf(String line) => line.length - line.trimLeft().length;
