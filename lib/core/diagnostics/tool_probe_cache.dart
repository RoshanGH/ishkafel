import '../audio/vocal_separator.dart';
import '../ffmpeg/process_runner.dart';
import '../miaoa/miaoa_locator.dart';

/// 忘掉所有「没找到某个工具」的探测结论，让下一次解析重新看一眼磁盘。
///
/// 为什么要有这么一个汇合点：外部工具的路径分散在三个定位器里各自缓存
/// （ffmpeg/ffprobe、miaoa、audio-separator）。缓存本身是必要的——否则每起
/// 一次子进程都要做磁盘探测——但**未命中的结论不能永久有效**：用户是在 app
/// 开着的时候去装工具的，装完还显示「未安装」，他只会以为工具没装对，
/// 而不会想到要重启 app。
///
/// 真机事故（2026-09-06）：ffmpeg 之外的两个工具是在 app 启动两小时后装的，
/// 「运行环境」页点多少次「重新检测」都还是未安装——按钮只重跑了最外层的
/// 采集，底下三层缓存一动没动。
///
/// 已命中的结果保留：路径不会凭空变化，重探是白花开销。
///
/// **新增一种外部工具时只改这一处**——漏掉的那个就会重犯上面那个 bug。
void forgetToolProbeMisses() {
  sharedMediaToolsLocator.forgetMisses();
  forgetMiaoaProbeMisses();
  forgetVocalSeparatorProbeMisses();
}
