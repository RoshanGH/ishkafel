import '../log/app_log.dart';

/// 把 miaoa CLI 的退出码 + stderr 翻译成用户能据以行动的中文。
///
/// 抽出来共用：分镜库检索与音频库检索撞上的是同一批故障（登录失效、没权限、
/// 没装 CLI、超时），两处各写一份必然会分叉——用户在一个入口看到「请执行
/// miaoa auth login」，在另一个入口只看到「失败」。
///
/// 原始 stderr 只进日志：`exit status 1` 这种既不解释发生了什么，
/// 也不告诉用户能做什么。
String miaoaFriendlyError(int exitCode, String stderr) {
  final lower = stderr.toLowerCase();
  if (lower.contains('401') || lower.contains('unauthorized')) {
    return '素材库登录已失效，请在终端执行 miaoa auth login 后重试';
  }
  if (lower.contains('403') || lower.contains('forbidden')) {
    return '没有访问该素材库的权限，请联系素材库管理员';
  }
  if (lower.contains('not found') || lower.contains('no such file')) {
    return '未检测到 miaoa 命令行工具，请先安装后重试';
  }
  if (lower.contains('timed out') || lower.contains('timeout')) {
    return '连接素材库超时，请检查网络后重试';
  }
  AppLog.warn('miaoa 检索失败（exit=$exitCode）：$stderr');
  return '素材库检索失败，请稍后重试';
}
