import 'dart:convert';

import '../ffmpeg/process_runner.dart';
import '../log/app_log.dart';
import 'miaoa_failure.dart';
import 'miaoa_locator.dart';

/// 一次登录动作的结果。失败时 [message] 是**能直接展示**的中文。
class MiaoaAuthResult {
  final bool ok;

  /// 失败成因；成功时为 null
  final MiaoaFailureKind? kind;

  /// 成功时是一句确认（如「验证码已发送」），失败时是该怎么办
  final String message;

  const MiaoaAuthResult.success(this.message)
      : ok = true,
        kind = null;

  const MiaoaAuthResult.failure(this.kind, this.message) : ok = false;
}

/// 验证码登录之外还有的几种失败——CLI 只会在报文里说，这里认出来分开讲。
///
/// 「验证码错」和「登录已失效」是两码事：前者重填一次就好，后者要重新走整个
/// 流程。都糊成「登录失败」会让用户在错误的方向上反复试。
enum _SmsProblem { wrongCode, expiredCode, tooFrequent, badPhone }

const _smsKeywords = <_SmsProblem, List<String>>{
  _SmsProblem.expiredCode: ['expired', '已过期', 'code expired', '超时失效'],
  _SmsProblem.wrongCode: [
    'invalid verification code',
    'invalid code',
    'incorrect code',
    'wrong code',
    '验证码错误',
    '验证码不正确',
  ],
  _SmsProblem.tooFrequent: [
    'rate limit',
    'too many',
    'too frequent',
    '频繁',
    '请稍后',
  ],
  _SmsProblem.badPhone: [
    'invalid phone',
    'phone number',
    '手机号',
  ],
};

/// 在 app 里登录 miaoa（手机号 + 短信验证码，两步）。
///
/// **凭据仍然由 CLI 存，这里一个字节都不留。** 做的只是把手机号和验证码转发
/// 给 `miaoa auth login` 跑一次；token 写在哪、什么时候过期、怎么续，全是 CLI
/// 的事。自己再存一份的话就有了两份登录态——app 显示「已登录」而 CLI 那边早
/// 过期，一检索就 401，用户完全看不懂。
///
/// 为什么要做进 app：CLI 支持 `--phone` / `--code` 两步走且不需要浏览器
/// （`miaoa auth login --help`）。此前未登录时界面上写的是「请在终端运行
/// miaoa auth login」——让用户离开这个 app 去敲命令，不是商业软件该有的样子。
///
/// **已知的取舍**：手机号和验证码是作为命令行参数传给子进程的，因此会短暂
/// 出现在本机进程列表里（`ps` 可见）。CLI 只提供这一种非交互入口，绕不开；
/// 验证码几分钟即失效，且这两样都不会被本 app 写进任何文件或日志。
class MiaoaAuthService {
  final ProcessRunner run;
  final String Function() resolveBinary;

  /// 默认国家码。CLI 的默认值也是 +86，显式传是为了让命令自解释
  final String countryCode;

  MiaoaAuthService({
    ProcessRunner? run,
    String Function()? resolveBinary,
    this.countryCode = '+86',
  })  : run = run ?? systemProcessRunner,
        resolveBinary = resolveBinary ?? resolveMiaoaBinary;

  /// 第一步：给这个手机号发验证码
  Future<MiaoaAuthResult> requestCode({required String phone}) async {
    final normalized = normalizePhone(phone);
    if (normalized == null) return _badPhone();
    return _login(
      ['--phone', normalized, '--country-code', countryCode, '--json'],
      onSuccess: '验证码已发送，请查收短信',
      what: '发送验证码',
    );
  }

  /// 第二步：拿验证码换登录态
  Future<MiaoaAuthResult> completeLogin({
    required String phone,
    required String code,
  }) async {
    final normalized = normalizePhone(phone);
    if (normalized == null) return _badPhone();
    final trimmed = code.trim();
    if (trimmed.isEmpty) {
      return const MiaoaAuthResult.failure(null, '请填写短信验证码');
    }
    return _login(
      [
        '--phone', normalized,
        '--code', trimmed,
        '--country-code', countryCode,
        '--json',
      ],
      onSuccess: '已登录',
      what: '登录',
      // CLI 可能退出码 0 却在 JSON 里说没成——那不能报喜
      requireLoggedIn: true,
    );
  }

  /// 退出登录：由 CLI 吊销 token 并清掉本地凭据
  Future<MiaoaAuthResult> logout() async {
    try {
      final result = await run(resolveBinary(), ['auth', 'logout', '--json']);
      if (result.exitCode == 0) {
        return const MiaoaAuthResult.success('已退出登录');
      }
      return _classify('${result.stderr}${result.stdout}', '退出登录');
    } catch (e) {
      return _classify(e, '退出登录');
    }
  }

  Future<MiaoaAuthResult> _login(
    List<String> args, {
    required String onSuccess,
    required String what,
    bool requireLoggedIn = false,
  }) async {
    try {
      final result = await run(resolveBinary(), ['auth', 'login', ...args]);
      final text = '${result.stderr}${result.stdout}';
      if (result.exitCode != 0) return _classify(text, what);
      if (requireLoggedIn && !_saysLoggedIn(result.stdout)) {
        return _classify(text, what);
      }
      return MiaoaAuthResult.success(onSuccess);
    } catch (e) {
      return _classify(e, what);
    }
  }

  /// CLI 说登录成功了吗。解不出 JSON 时按「成功」处理——退出码已经是 0，
  /// 再因为报文格式变了就判失败，等于把一次真的登录说成失败
  bool _saysLoggedIn(Object? stdout) {
    final text = '${stdout ?? ''}'.trim();
    if (text.isEmpty) return true;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return true;
      return decoded['loggedIn'] != false && decoded['success'] != false;
    } catch (_) {
      return true;
    }
  }

  MiaoaAuthResult _classify(Object error, String what) {
    // 原始报文只进日志，且这条路径上没有手机号/验证码
    final kind = classifyMiaoaFailure(error);
    AppLog.warn('miaoa $what 失败（$kind）');
    final sms = _smsProblemOf(error);
    if (sms != null) return MiaoaAuthResult.failure(kind, _smsGuidance(sms));
    return MiaoaAuthResult.failure(kind, _authGuidance(kind, what));
  }

  static _SmsProblem? _smsProblemOf(Object error) {
    final text = error.toString().toLowerCase();
    for (final entry in _smsKeywords.entries) {
      if (entry.value.any(text.contains)) return entry.key;
    }
    return null;
  }

  static String _smsGuidance(_SmsProblem problem) => switch (problem) {
        _SmsProblem.wrongCode => '验证码不正确，请检查后重填',
        _SmsProblem.expiredCode => '验证码已过期，请重新获取',
        _SmsProblem.tooFrequent => '获取太频繁了，请过一分钟再试',
        _SmsProblem.badPhone => '这个手机号 miaoa 不认，请确认是注册时用的那个',
      };

  static String _authGuidance(MiaoaFailureKind kind, String what) =>
      switch (kind) {
        MiaoaFailureKind.cliMissing =>
          '未检测到 miaoa 命令行工具。请先安装 miaoa CLI 并确认它在 PATH 中。',
        MiaoaFailureKind.forbidden => '这个账号没有登录本工具的权限，请联系 miaoa 管理员。',
        MiaoaFailureKind.notFound => '这个手机号在 miaoa 上没有对应账号。',
        MiaoaFailureKind.network => '连接 miaoa 失败，请检查网络后重试。',
        _ => '$what失败，请稍后重试。',
      };

  static MiaoaAuthResult _badPhone() => const MiaoaAuthResult.failure(
      null, '请填写 11 位手机号');
}

/// 手机号规整：去掉空格、横杠、括号这些从通讯录粘过来会带上的字符，
/// 校验成 11 位数字。不合规返回 null——**在边界处挡住，不白跑一趟子进程**，
/// 也不让一个明显错的号去占用短信配额。
String? normalizePhone(String raw) {
  final digits = raw.replaceAll(RegExp(r'[\s\-()（）+]'), '');
  if (digits.length != 11) return null;
  if (!RegExp(r'^\d{11}$').hasMatch(digits)) return null;
  return digits;
}
