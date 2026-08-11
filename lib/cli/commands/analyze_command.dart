import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../app/service_wiring.dart';
import '../../core/ai/ai_credentials.dart';
import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_lock.dart';
import '../cli_output.dart';
import '../task_view.dart';

/// `ishkafel analyze <task>`
///
/// 跑完整分析：抽音频 → 分离 → ASR → 语义切分 → 场景检测 → 打标 → 建单元。
///
/// **这一版全部走内置 AI**。把其中几步外包给调用方（`--external`）是下一步
/// 的事，边界见 spec 第三节：能外包的是输出可验证的那几步（语义切分、打标、
/// 切点矫正），ASR 不行——它的时间戳偏 200ms 就毁掉整条链，而且不会报错。
Future<int> runAnalyzeCommand({
  required List<String> rest,
  required Directory dataDir,
  String holder = 'agent',
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('用法：ishkafel analyze <任务 id>');
    return exitBadUsage;
  }
  final id = rest.first;

  final repository = FileTaskRepository(dataDir);
  final task = await repository.findById(id);
  if (task == null) {
    sink.writeln('没有这个任务：$id');
    return exitNotFound;
  }

  final credentials = loadCliCredentials(dataDir);
  if (!credentials.isComplete) {
    // 这里必须说清楚怎么办：CLI 是单独编译的，GUI 那份 --dart-define 编进去
    // 的凭据带不过来
    sink.writeln('缺少 AI 凭据，无法分析。把 ark_api_key / speech_app_id / '
        'speech_access_token 三个文件放到：\n'
        '  ${p.join(dataDir.path, 'credentials')}/\n'
        '或者用环境变量 ARK_API_KEY / SPEECH_APP_ID / SPEECH_ACCESS_TOKEN');
    return 1;
  }

  final pipeline = buildAnalysisPipeline(credentials, dataDir);
  if (pipeline == null) {
    sink.writeln('分析流水线装配失败（凭据不完整）');
    return 1;
  }

  final lock = TaskLockFile(dataDir: dataDir, taskId: id);
  if (!lock.acquire(holder)) {
    sink.writeln('${lock.read()?.holder ?? '别人'} 正在操作这个任务，分析不了');
    return exitLocked;
  }
  // 分析要跑好几分钟，中途得续命，否则锁会在 60 秒后被判失效
  final heartbeat =
      Timer.periodic(const Duration(seconds: 20), (_) => lock.heartbeat(holder));

  try {
    final analyzed = await pipeline.analyze(
      task,
      onProgress: (progress) => sink.writeln('· ${progress.stage.name}'),
    );
    if (analyzed.analysisError case final failure?) {
      sink.writeln('分析失败：$failure');
      return 1;
    }
    emitJson(taskToJson(analyzed), out: out);
    return 0;
  } catch (e) {
    sink.writeln('分析失败：$e');
    return 1;
  } finally {
    heartbeat.cancel();
    lock.release(holder);
  }
}

/// CLI 的凭据来源。
///
/// **和 GUI 不是一回事**：GUI 那份是 `--dart-define` 在编译期注入的，而 CLI
/// 是单独编译的二进制，带不过来。所以只能从环境变量或凭据目录读——读不到时
/// 上面会把该放哪儿说清楚，而不是让分析跑到一半报一个 401。
AiCredentials loadCliCredentials(Directory dataDir) =>
    CredentialsLoader.load(secretsDirs: [
      Directory(p.join(dataDir.path, 'credentials')),
      Directory(p.join(Directory.current.path, '.secrets')),
    ]);
