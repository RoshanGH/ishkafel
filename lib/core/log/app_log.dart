import 'dart:io';

import 'package:flutter/foundation.dart';

/// 轻量日志出口：统一前缀，后续里程碑可替换为文件日志
///
/// 出口用 `stderr` 而不是 `debugPrint`：真机以 `open` 或直接跑
/// `xxx.app/Contents/MacOS/xxx` 启动时，`debugPrint` 的输出**完全不进
/// stdout**——M3 真机验收踩过这个坑，一个「绘制中途抛异常导致整帧后续绘制
/// 全部丢失」的故障在日志里查无痕迹，只能靠逐段插桩重建才定位到。
abstract final class AppLog {
  /// 日志出口，测试可替换以捕获输出
  static void Function(String line) sink = _writeToStderr;

  static void warn(String message) => sink('[ishkafel][warn] $message');
  static void info(String message) => sink('[ishkafel][info] $message');

  static void _writeToStderr(String line) => stderr.writeln(line);

  /// 把 Flutter 框架上报的异常（渲染/手势/构建期错误等）转发进本日志。
  ///
  /// 框架默认经 `debugPrint` 打印错误横幅，在上述真机启动方式下不可见；
  /// 这里在**保留**原有处理链（继续调用先前的 `FlutterError.onError`，缺省
  /// 时为 `FlutterError.presentError`）的前提下补一条 stderr 出口，
  /// 保证「错误不被静默吞掉」。应在 `main()` 尽早调用一次。
  static void installFlutterErrorForwarding() {
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      final where = details.library == null ? '' : '（${details.library}）';
      warn('Flutter 框架异常$where：${details.exceptionAsString()}');
      previous?.call(details);
    };
  }
}
