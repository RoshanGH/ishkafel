import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 可视模式得覆盖**最慢最贵的那几步**，不然它没什么用。
///
/// 验收 Agent 的原话：
///
/// > 最花时间的几步恰好不支持可视……可视模式真正动起来是从挑镜头才开始。
///
/// **这个文件原来守的是「界面把写锁让出来」那套机制**（`lock.yield`、
/// 只读跟随、「我来接手」）——它是在绕一个死结：可视模式要求界面停在这个
/// 任务上，而写这个任务要求界面不能停在上面。2026-09-18 整套锁删掉之后
/// 死结本身消失了，那几条断言也就没有对象了。
///
/// 留下来的是**死结底下那件真正要守的事**：识别台词、逐句配音、导出
/// ——几分钟、几十句 TTS、直接出交付物——这几条命令必须**收得到
/// `--visual`**。收不到的命令只能裸写播报：横幅上念得挺热闹，界面却停在
/// 任务列表一动不动（真机上 extract / voice 两条正是如此）。
///
/// 「报进度、带分母、界面跟到那一行」由 `slow_steps_show_progress_test`
/// 守，这里不重复。
void main() {
  final run =
      File('lib/cli/commands/script_run_command.dart').readAsStringSync();

  /// 从某个命令的函数头截到下一个 `Future<int> run` 为止
  String bodyOf(String signature) {
    final start = run.indexOf(signature);
    expect(start, isNot(-1), reason: '$signature 还在吧');
    final next = run.indexOf('\nFuture<int> run', start + signature.length);
    return next < 0 ? run.substring(start) : run.substring(start, next);
  }

  for (final (name, signature) in const [
    ('识别台词', 'Future<int> runScriptExtractCommand'),
    ('逐句配音', 'Future<int> runScriptVoiceCommand'),
    ('导出成片', 'Future<int> runScriptExportCommand'),
  ]) {
    test('$name 收得到 --visual，并且真的把界面带到现场', () {
      final body = bodyOf(signature);
      expect(body, contains('bool? visual'),
          reason: '收不到这个标志的命令只能裸写播报——'
              '横幅上念得挺热闹，界面却停在任务列表一动不动');
      expect(body, contains('AgentStageMode.from(visual: visual)'),
          reason: '收到了不用等于没收到');
      expect(body, contains("module: 'director'"),
          reason: '不说去哪个模块，界面就不会进那个任务');
    });
  }

  test('这几步不会因为「有人占着」而走不下去', () {
    expect(run.contains('lock.acquire('), isFalse,
        reason: '可视模式下人正开着那一页是常态。'
            '一把锁挡在这儿，最该让人看见的几步就恰恰因为「人在看」而做不了');
    expect(run.contains('exitLocked'), isFalse);
  });
}
