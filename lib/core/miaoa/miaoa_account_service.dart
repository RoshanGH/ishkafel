import 'dart:convert';

import '../log/app_log.dart';
import 'miaoa_failure.dart';
import 'miaoa_gateway.dart';

/// 账号状态读取失败的描述（分类 + 可直接展示的中文引导）
class MiaoaAccountFailure {
  final MiaoaFailureKind kind;
  final String message;

  const MiaoaAccountFailure({required this.kind, required this.message});
}

/// miaoa 账号与工作上下文的快照（不可变）。
///
/// [maskedAccount] 是**脱敏后**的登录标识——服务层就把原值丢掉，不给上层
/// 任何「不小心显示出来」的机会。
class MiaoaAccountStatus {
  final bool loggedIn;
  final String? maskedAccount;
  final String? tenantName;
  final String? projectName;
  final int? projectCount;
  final String? endpoint;

  /// 非空表示这次读取本身失败了（区别于「读到了，但没登录」）
  final MiaoaAccountFailure? failure;

  const MiaoaAccountStatus({
    required this.loggedIn,
    this.maskedAccount,
    this.tenantName,
    this.projectName,
    this.projectCount,
    this.endpoint,
    this.failure,
  });

  const MiaoaAccountStatus.failed(MiaoaAccountFailure this.failure)
      : loggedIn = false,
        maskedAccount = null,
        tenantName = null,
        projectName = null,
        projectCount = null,
        endpoint = null;
}

/// 登录标识脱敏：手机号留前 3 后 4，其余一律只留首字符。
///
/// 设置页会被截图、投屏、录屏，完整手机号属于个人信息，界面上任何位置都不
/// 该出现。空白输入返回 null（当作「没有账号」），而不是返回一串星号——
/// 那会让界面显示一个不存在的账号。
String? maskAccount(String? raw) {
  final value = raw?.trim() ?? '';
  if (value.isEmpty) return null;
  if (value.length >= 8) {
    return '${value.substring(0, 3)}****${value.substring(value.length - 4)}';
  }
  return '${value.substring(0, 1)}${'*' * (value.length - 1)}';
}

/// 面向用户的中文引导（账号语境；标签组语境的措辞见 [miaoaFailureGuidance]）
String accountFailureGuidance(MiaoaFailureKind kind) => switch (kind) {
      MiaoaFailureKind.cliMissing =>
        '未检测到 miaoa 命令行工具。请先安装 miaoa CLI 并确认它在 PATH 中，'
            '然后点「重试」；命令行那头装好后重跑一次原来的命令即可。',
      MiaoaFailureKind.unauthorized =>
        'miaoa 登录已失效。请在终端运行 miaoa auth login 重新登录，再点「重试」。',
      MiaoaFailureKind.forbidden => '当前 miaoa 账号没有读取账号信息的权限，请联系 miaoa 管理员。',
      MiaoaFailureKind.notFound => '未找到 miaoa 账号信息，请在终端运行 miaoa auth login 后重试。',
      MiaoaFailureKind.network => '连接 miaoa 失败，请检查网络后点「重试」。',
      MiaoaFailureKind.unknown => '读取 miaoa 账号状态失败。可在终端运行 '
          'miaoa auth status 查看具体原因。',
    };

/// 读取 miaoa 登录状态、租户与当前项目。
///
/// 只跑 `auth status`——纯读操作，不触发登录、不改上下文。登录本身由 CLI
/// 完成（短信验证码/设备流），app 不代收凭据。
class MiaoaAccountService {
  final MiaoaGateway gateway;

  MiaoaAccountService({MiaoaGateway? gateway})
      : gateway = gateway ?? MiaoaGateway();

  Future<MiaoaAccountStatus> fetch() async {
    try {
      // 人类可读输出的措辞随时会改，靠正则扒字段迟早会静默失效
      final result = await gateway.raw(['auth', 'status', '--json']);
      final json = _tryDecode(result.stdout);
      if (json == null) {
        // 拿不到结构化输出时，退出码与 stderr 才是判断依据
        return _failure(result.exitCode == 0
            ? '${result.stdout}'
            : '${result.stderr}'.isNotEmpty
                ? '${result.stderr}'
                : '${result.stdout}');
      }
      return _parse(json);
    } catch (e) {
      return _failure(e);
    }
  }

  MiaoaAccountStatus _parse(Map<String, dynamic> json) {
    // CLI 升级后换字段名 / 少给一层是常态，缺什么就是 null，不该让设置页白屏
    final user = json['user'];
    final userMap = user is Map<String, dynamic> ? user : const {};
    final tenant = userMap['tenant'];
    final project = userMap['project'];
    return MiaoaAccountStatus(
      loggedIn: json['loggedIn'] == true,
      maskedAccount: maskAccount(_string(userMap['username'])),
      tenantName: tenant is Map ? _string(tenant['tenantName']) : null,
      projectName: project is Map ? _string(project['name']) : null,
      projectCount: json['projects'] is int ? json['projects'] as int : null,
      endpoint: _string(json['endpoint']),
    );
  }

  MiaoaAccountStatus _failure(Object error) {
    final kind = classifyMiaoaFailure(error);
    // 原始报文进日志，不摊给用户；且日志里不会有账号明文（此路径拿不到 user）
    AppLog.warn('读取 miaoa 账号状态失败（$kind）');
    return MiaoaAccountStatus.failed(
        MiaoaAccountFailure(kind: kind, message: accountFailureGuidance(kind)));
  }

  static Map<String, dynamic>? _tryDecode(Object? stdout) {
    final text = '${stdout ?? ''}'.trim();
    if (text.isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static String? _string(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
