import 'package:flutter/foundation.dart';

import '../core/log/app_log.dart';

/// 把 Flutter 框架上报的异常（渲染/手势/构建期错误等）转发进本日志。
///
/// 框架默认经 `debugPrint` 打印错误横幅，在上述真机启动方式下不可见；
/// 这里在**保留**原有处理链（继续调用先前的 `FlutterError.onError`，缺省
/// 时为 `FlutterError.presentError`）的前提下补一条 stderr 出口，
/// 保证「错误不被静默吞掉」。应在 `main()` 尽早调用一次。
void installFlutterErrorForwarding() {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    final where = details.library == null ? '' : '（${details.library}）';
  AppLog.warn('Flutter 框架异常$where：${details.exceptionAsString()}');
    previous?.call(details);
  };
  }
