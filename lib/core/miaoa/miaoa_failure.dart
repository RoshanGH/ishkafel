import 'dart:io';

import 'miaoa_exception.dart';

/// miaoa CLI 失败的成因分类。
///
/// 分类的意义是「用户下一步该做什么」各不相同：未登录要去终端登录、没装要去
/// 安装、403 要去找管理员开权限。把它们糊成一句「加载失败，请重试」等于把人
/// 困在原地反复点重试。
enum MiaoaFailureKind {
  /// miaoa 命令行工具不存在或不在 PATH 中（子进程根本起不来）
  cliMissing,

  /// 401：未登录或 token 已失效。**不自动重试**，须用户手动 `miaoa auth login`
  unauthorized,

  /// 403：账号没有该资源的权限。停止，不重试、不创建占位资源
  forbidden,

  /// 404：资源不存在。停止，不重试、不创建占位资源
  notFound,

  /// 网络不可达 / 超时 / DNS 解析失败
  network,

  /// 认不出来的失败：给通用引导 + 自查命令，不冒充成其他原因
  unknown,
}

/// 关键词按「先专有后宽泛」的顺序匹配，避免 401 的报文里带 timeout 之类的
/// 词而被误判成网络问题
const _kindKeywords = <MiaoaFailureKind, List<String>>{
  // shell 起不来子进程时这些话会落在 stderr 文本里（而非 ProcessException）
  MiaoaFailureKind.cliMissing: [
    'no such file or directory',
    'command not found',
    'executable file not found',
  ],
  MiaoaFailureKind.unauthorized: [
    '401',
    'unauthorized',
    'unauthenticated',
    '未登录',
    '登录已失效',
    'token expired',
    'invalid token',
  ],
  MiaoaFailureKind.forbidden: ['403', 'forbidden', '无权限', '权限不足'],
  MiaoaFailureKind.notFound: ['404', 'not found', '不存在'],
  MiaoaFailureKind.network: [
    'connection refused',
    'connection reset',
    'no such host',
    'network is unreachable',
    'i/o timeout',
    'timeout',
    'timed out',
    'deadline exceeded',
    'dial tcp',
    '网络',
  ],
};

/// 把任意异常归入 [MiaoaFailureKind]。纯函数，便于单测穷举各种 CLI 报文。
MiaoaFailureKind classifyMiaoaFailure(Object error) {
  // 网关抛出的异常已经分类过了，认它的——关键词匹配只对原始报文有效，
  // 对翻译后的中文引导会一律误判成 unknown
  if (error is MiaoaException && error.kind != MiaoaFailureKind.unknown) {
    return error.kind;
  }
  // 子进程起不来只有一种现实成因：可执行文件不在 PATH 里
  if (error is ProcessException) return MiaoaFailureKind.cliMissing;
  final text = _errorText(error).toLowerCase();
  for (final entry in _kindKeywords.entries) {
    if (entry.value.any(text.contains)) return entry.key;
  }
  return MiaoaFailureKind.unknown;
}

String _errorText(Object error) =>
    error is MiaoaException ? error.message : error.toString();

/// 面向用户的中文引导：说清「发生了什么」+「你现在能做什么」。
/// 不含原始异常文本——那些进日志（[AppLog]），不摊给用户。
String miaoaFailureGuidance(MiaoaFailureKind kind) => switch (kind) {
      MiaoaFailureKind.cliMissing =>
        '未检测到 miaoa 命令行工具。请先安装 miaoa CLI 并确认它在 PATH 中，'
            '然后重新打开这个窗口。',
      MiaoaFailureKind.unauthorized =>
        'miaoa 登录已失效。请在终端运行 miaoa auth login 重新登录，再点「重试」。',
      MiaoaFailureKind.forbidden =>
        '当前 miaoa 账号没有读取标签组的权限。请联系 miaoa 管理员开通后再试。',
      MiaoaFailureKind.notFound => '这个标签组在 miaoa 上已不存在，请点「重试」重新拉取列表。',
      MiaoaFailureKind.network => '连接 miaoa 失败，请检查网络后点「重试」。',
      MiaoaFailureKind.unknown => '读取 miaoa 标签组失败。请点「重试」；'
          '若一直失败，可在终端运行 miaoa tag group list 查看具体原因。',
    };

/// [classifyMiaoaFailure] + [miaoaFailureGuidance] 的组合快捷方式
String miaoaFriendlyMessage(Object error) =>
    miaoaFailureGuidance(classifyMiaoaFailure(error));
