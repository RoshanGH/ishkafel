import 'dart:io';

import 'media_tools_locator.dart';

/// 子进程执行抽象（生产用 [systemProcessRunner]，测试注入假实现）
typedef ProcessRunner = Future<ProcessResult> Function(
    String executable, List<String> args);

/// 真正拉起子进程的底层动作（注入点：测试可替换，无需真实二进制）
typedef ProcessInvoker = Future<ProcessResult> Function(
    String executable, List<String> args);

/// 全局共享的工具定位器：解析结果缓存在实例上，各服务复用同一份避免重复探测
final MediaToolsLocator sharedMediaToolsLocator = MediaToolsLocator();

/// 默认实现：先把裸名（ffmpeg/ffprobe）解析成绝对路径，再拉起子进程
Future<ProcessResult> systemProcessRunner(
        String executable, List<String> args) =>
    ResolvingProcessRunner(locator: sharedMediaToolsLocator)(executable, args);

/// 解析型执行器：把 `ffmpeg`/`ffprobe` 这类裸名解析为绝对路径后再执行。
///
/// GUI（Finder/`open`）启动的进程 PATH 不含 Homebrew 目录，裸名调用必然
/// ENOENT，因此统一在这一层收口；解析不到时抛出带中文引导的
/// [FfmpegException]，而不是把 `ProcessException` 原文摊给用户。
class ResolvingProcessRunner {
  final MediaToolsLocator locator;
  final ProcessInvoker invoke;

  ResolvingProcessRunner({
    MediaToolsLocator? locator,
    ProcessInvoker? invoke,
  })  : locator = locator ?? sharedMediaToolsLocator,
        invoke = invoke ?? Process.run;

  /// 声明为 async：解析失败的异常要落到返回的 Future 上，
  /// 而不是在调用瞬间同步抛出（同步抛出会绕过调用方的 await 错误处理）
  Future<ProcessResult> call(String executable, List<String> args) async {
    final resolved = _resolve(executable);
    return invoke(resolved, args);
  }

  /// 已经是绝对路径时直接透传，不做解析
  String _resolve(String executable) {
    if (executable.startsWith('/')) return executable;
    final resolved = locator.resolve(executable);
    if (resolved == null) throw FfmpegException(missingToolMessage(executable));
    return resolved;
  }
}

/// 工具缺失时给用户的中文引导（面向用户，不含技术堆栈）
String missingToolMessage(String executable) =>
    '未找到视频处理组件 $executable。请先在终端执行 brew install ffmpeg 完成安装，'
    '然后重新启动本应用。';

/// ffmpeg/ffprobe 执行失败
class FfmpegException implements Exception {
  final String message;
  const FfmpegException(this.message);
  @override
  String toString() => 'FfmpegException: $message';
}
