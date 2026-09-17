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
  /// 白名单：这几处是写入口自己，或者根本不改已存在的任务
  const allowed = {
    'lib/core/storage/task_mutation.dart', // 写入口本人
    'lib/core/storage/file_task_repository.dart',
    'lib/core/storage/task_repository.dart',
  };

  /// 扫描范围分两步走：Task 6 先管住 CLI，Task 7 再扩到整个 lib。
  /// 一上来就扫全 lib 的话，Task 6 做完它照样是红的（界面还没迁），
  /// 那这条测试就没法当 Task 6 的验收门。
  const scanRoot = 'lib/cli'; // ← Task 7 改成 'lib'

  test('除了 TaskMutation，没有别的地方直接 save 任务', () {
    final offenders = <String>[];
    for (final f in Directory(scanRoot)
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final rel = f.path.replaceFirst('${Directory.current.path}/', '');
      if (allowed.contains(rel)) continue;
      final src = f.readAsStringSync();
      for (final m in RegExp(r'\b(\w+)\.save\(').allMatches(src)) {
        final receiver = m.group(1)!;
        // 只认任务仓库那一类接收者，别把别的 save 误伤了
        if (!RegExp(r'repo|repository|tasks?Repo', caseSensitive: false)
            .hasMatch(receiver)) continue;
        offenders.add('$rel → $receiver.save(');
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
