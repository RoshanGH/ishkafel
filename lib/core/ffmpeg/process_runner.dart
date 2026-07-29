import 'dart:io';

/// 子进程执行抽象（生产用 Process.run，测试注入假实现）
typedef ProcessRunner = Future<ProcessResult> Function(
    String executable, List<String> args);

/// 默认实现：直接调系统进程
Future<ProcessResult> systemProcessRunner(
        String executable, List<String> args) =>
    Process.run(executable, args);

/// ffmpeg/ffprobe 执行失败
class FfmpegException implements Exception {
  final String message;
  const FfmpegException(this.message);
  @override
  String toString() => 'FfmpegException: $message';
}
