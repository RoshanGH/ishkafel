import 'dart:io';


/// 轻量日志出口：统一前缀，后续里程碑可替换为文件日志
///
/// 出口用 `stderr` 而不是 `debugPrint`：真机以 `open` 或直接跑
/// `xxx.app/Contents/MacOS/xxx` 启动时，`debugPrint` 的输出**完全不进
/// stdout**——M3 真机验收踩过这个坑，一个「绘制中途抛异常导致整帧后续绘制
/// 全部丢失」的故障在日志里查无痕迹，只能靠逐段插桩重建才定位到。
abstract final class AppLog {
  /// 日志出口，测试可替换以捕获输出
  static void Function(String line) sink = _writeToStderr;

  /// 真出事了：该出的东西没出来、用户拿不到结果。
  /// 和 warn 分开是因为 warn 用得太随意，一屏里全是它，
  /// 「三条成片一条都没导出来」混在中间会被人和脚本一起滑过去
  static void error(String message) => sink('[ishkafel][error] $message');

  static void warn(String message) => sink('[ishkafel][warn] $message');
  static void info(String message) => sink('[ishkafel][info] $message');

  static void _writeToStderr(String line) => stderr.writeln(line);
}
