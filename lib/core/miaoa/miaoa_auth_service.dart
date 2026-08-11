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

/// 一个可切换的目标：企业（租户）或项目。
class MiaoaWorkspace {
  final int id;
  final String name;

  /// 当前就在这个上面吗
  final bool current;

  const MiaoaWorkspace({
    required this.id,
    required this.name,
    this.current = false,
  });
}

/// 列一批可选项的结果。失败时 [failure] 是能直接展示的中文
class MiaoaWorkspaceList {
  final List<MiaoaWorkspace> items;
  final String? failure;

  const MiaoaWorkspaceList(this.items) : failure = null;
  const MiaoaWorkspaceList.failed(String this.failure) : items = const [];

  bool get ok => failure == null;
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

  /// 这个账号能进哪几家企业。
  ///
  /// **登录之后必须让用户选一次**：一个账号可以属于多家企业，而
  /// **标签组是企业级的**。落在错的企业上，新建任务时根本选不到标签组，
  /// 于是没有受控词表、AI 打不出标签，到了挑替换素材那一步就是「没有标签」
  /// ——而这中间没有任何一步会报错，全是静默的。
  Future<MiaoaWorkspaceList> listTenants({int? currentId}) =>
      _list(['tenant', 'list', '--json'], '读取企业列表', (json) {
        final raw = json['tenants'];
        if (raw is! List) return const [];
        return [
          for (final t in raw)
            if (t is Map && t['tenantId'] is int)
              MiaoaWorkspace(
                id: t['tenantId'] as int,
                name: '${t['tenantName'] ?? '未命名企业'}',
                current: t['tenantId'] == currentId,
              ),
        ];
      });

  /// 切到这家企业。CLI 会顺带把本地凭证换成新会话
  Future<MiaoaAuthResult> selectTenant(int tenantId) =>
      _act(['tenant', 'select', '$tenantId', '--json'], '切换企业', '已切换企业');

  /// 一次拉多少个项目。CLI 默认只给 20，而真实企业里有几十上百个
  static const int _pageSize = 100;

  /// 最多翻几页。纯粹是防跑飞——真要有一万个项目，选择器也不是这么用的
  static const int _maxPages = 20;

  /// 当前企业下有哪些项目。**要翻页拉全**。
  ///
  /// 真机上撞过：CLI 默认 page-size=20，而这个企业有 69 个项目；再加上当时
  /// 在客户端把停用的滤掉，界面上只剩 10 个。用户看到的是「项目列表不全」，
  /// 而列表本身一声不吭——它并不知道自己只拿到了第一页。
  ///
  /// 停用的交给服务端过滤（`--enabled-only`）：在客户端滤会让每页拿到的条数
  /// 参差不齐，翻页逻辑立刻就不准了。
  Future<MiaoaWorkspaceList> listProjects({int? currentId}) async {
    final items = <MiaoaWorkspace>[];
    for (var page = 1; page <= _maxPages; page++) {
      final result = await _list(
        [
          'project', 'list',
          '--enabled-only',
          '--page', '$page',
          '--page-size', '$_pageSize',
          '--json',
        ],
        '读取项目列表',
        (json) => _parseProjects(json, currentId),
      );
      if (!result.ok) {
        // 第一页就失败才算失败；后面某页断了，先把已经拿到的给用户用
        return items.isEmpty ? result : MiaoaWorkspaceList(items);
      }
      items.addAll(result.items);
      // 这一页没满，说明已经是最后一页
      if (result.items.length < _pageSize) break;
    }
    return MiaoaWorkspaceList(items);
  }

  static List<MiaoaWorkspace> _parseProjects(
      Map<String, dynamic> json, int? currentId) {
    final raw = json['records'];
    if (raw is! List) return const [];
    return [
      for (final p in raw)
        if (p is Map && p['id'] is int)
          MiaoaWorkspace(
            id: p['id'] as int,
            name: '${p['name'] ?? '未命名项目'}',
            current: p['id'] == currentId,
          ),
    ];
  }

  /// 让**服务端**按关键词搜项目（CLI 的 `--keyword`，匹配 ID 或名称）。
  ///
  /// 界面上的即时过滤是本地做的（列表已经整个在手，跑子进程只会让每敲一个字
  /// 都卡一下）。这一条是**补充**：服务端的匹配规则可能比本地的 contains 宽，
  /// 而且万一某个企业的项目多到拉不全，它是兜底。
  Future<MiaoaWorkspaceList> searchProjects(String keyword,
      {int? currentId}) async {
    final key = keyword.trim();
    if (key.isEmpty) return const MiaoaWorkspaceList([]);
    return _list(
      [
        'project', 'list',
        '--enabled-only',
        '--keyword', key,
        '--page-size', '$_pageSize',
        '--json',
      ],
      '搜索项目',
      (json) => _parseProjects(json, currentId),
    );
  }

  Future<MiaoaAuthResult> switchProject(int projectId) =>
      _act(['project', 'switch', '$projectId', '--json'], '切换项目', '已切换项目');

  Future<MiaoaWorkspaceList> _list(
    List<String> args,
    String what,
    List<MiaoaWorkspace> Function(Map<String, dynamic>) parse,
  ) async {
    try {
      final result = await run(resolveBinary(), args);
      if (result.exitCode != 0) {
        return MiaoaWorkspaceList.failed(
            _authGuidance(classifyMiaoaFailure('${result.stderr}${result.stdout}'), what));
      }
      final decoded = jsonDecode('${result.stdout}'.trim());
      if (decoded is! Map<String, dynamic>) {
        return MiaoaWorkspaceList.failed('$what失败：读不懂返回内容');
      }
      return MiaoaWorkspaceList(parse(decoded));
    } catch (e) {
      AppLog.warn('miaoa $what 失败（${classifyMiaoaFailure(e)}）');
      return MiaoaWorkspaceList.failed(
          _authGuidance(classifyMiaoaFailure(e), what));
    }
  }

  Future<MiaoaAuthResult> _act(
      List<String> args, String what, String onSuccess) async {
    try {
      final result = await run(resolveBinary(), args);
      if (result.exitCode == 0) return MiaoaAuthResult.success(onSuccess);
      return _classify('${result.stderr}${result.stdout}', what);
    } catch (e) {
      return _classify(e, what);
    }
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
