import 'package:flutter/foundation.dart';

/// 轻量日志出口：统一前缀，后续里程碑可替换为文件日志
abstract final class AppLog {
  static void warn(String message) => debugPrint('[ishkafel][warn] $message');
  static void info(String message) => debugPrint('[ishkafel][info] $message');
}
