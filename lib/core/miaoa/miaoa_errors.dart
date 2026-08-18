import 'dart:convert';


/// miaoa CLI 报错文本的提取。「报错 → 用户动作」的翻译只有一份，
/// 在 miaoa_gateway.dart 的 [miaoaExitException] 里。
/// CLI 把错误写在哪儿并不统一：多数故障进 stderr，而参数校验失败（如项目
/// 越权）是把 `{"error":{"message":...},"ok":false}` 写到 stdout 的。只看
/// stderr 会把一条讲清楚了的报错降级成「请稍后重试」。
String miaoaErrorText(String stdout, String stderr) {
  if (stderr.trim().isNotEmpty) return stderr;
  try {
    final decoded = jsonDecode(stdout.trim());
    final error = decoded is Map ? decoded['error'] : null;
    final message = error is Map ? error['message'] : null;
    if (message is String && message.isNotEmpty) return message;
  } catch (_) {
    // stdout 不是 JSON 就当没有额外信息，退回退出码本身
  }
  return stdout;
}
