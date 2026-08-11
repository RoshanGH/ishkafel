import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/app/flutter_error_bridge.dart';
import 'package:ishkafel/core/log/app_log.dart';

void main() {
  group('AppLog', () {
    late List<String> captured;
    late void Function(String) originalSink;

    setUp(() {
      captured = <String>[];
      originalSink = AppLog.sink;
      AppLog.sink = captured.add;
    });

    tearDown(() => AppLog.sink = originalSink);

    test('warn/info 带统一前缀写入可注入出口', () {
      AppLog.warn('磁盘写入失败');
      AppLog.info('分析开始');

      expect(captured, [
        '[ishkafel][warn] 磁盘写入失败',
        '[ishkafel][info] 分析开始',
      ]);
    });

    group('Flutter 框架错误转发（真机验收教训：绘制异常在日志里完全隐形）', () {
      late FlutterExceptionHandler? originalOnError;

      setUp(() => originalOnError = FlutterError.onError);
      tearDown(() => FlutterError.onError = originalOnError);

      test('安装转发后，框架上报的异常会经 AppLog 输出', () {
        installFlutterErrorForwarding();

        FlutterError.reportError(FlutterErrorDetails(
          exception: Exception('绘制中途抛异常'),
          library: 'rendering library',
          context: ErrorDescription('painting TimelinePainter'),
        ));

        expect(captured, isNotEmpty,
            reason: '框架异常必须进日志，否则真机上整帧绘制丢失这类故障查无痕迹');
        expect(captured.first, startsWith('[ishkafel][warn] '));
        expect(captured.first, contains('绘制中途抛异常'));
        expect(captured.first, contains('rendering library'));
      });

      test('转发不吞掉原有的 onError 处理链', () {
        var delegated = 0;
        FlutterError.onError = (_) => delegated++;

        installFlutterErrorForwarding();
        FlutterError.reportError(
            FlutterErrorDetails(exception: Exception('x')));

        expect(delegated, 1, reason: '原处理器仍应被调用，不能被替换掉');
        expect(captured, hasLength(1));
      });
    });
  });
}
