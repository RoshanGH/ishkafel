import 'dart:io';

/// AI 云端凭据（不可变）。使用者永远不接触——内部版打包注入，开发期读 .secrets
class AiCredentials {
  final String arkApiKey;
  final String speechAppId;
  final String speechAccessToken;

  const AiCredentials({
    required this.arkApiKey,
    required this.speechAppId,
    required this.speechAccessToken,
  });

  bool get isComplete =>
      arkApiKey.isNotEmpty &&
      speechAppId.isNotEmpty &&
      speechAccessToken.isNotEmpty;
}

/// 三级装载：--dart-define（打包注入）→ 环境变量 → 凭据文件目录
///
/// [secretsDirs] 是**一串**目录而不是一个：从 Finder 双击启动时进程的工作
/// 目录是 `/`，项目里那个 `.secrets` 永远找不到——只认一个目录等于打包出来
/// 的 app 一定没凭据，界面上常驻一句「尚未配置 AI 服务」而用户无从下手。
/// 按顺序逐项回落，靠前的目录优先。
class CredentialsLoader {
  static const _defineArk = String.fromEnvironment('ARK_API_KEY');
  static const _defineAppId = String.fromEnvironment('SPEECH_APP_ID');
  static const _defineToken = String.fromEnvironment('SPEECH_ACCESS_TOKEN');

  static AiCredentials load({
    Map<String, String>? env,
    List<Directory> secretsDirs = const [],
  }) {
    final e = env ?? Platform.environment;
    return AiCredentials(
      arkApiKey:
          _pick(_defineArk, e['ARK_API_KEY'], secretsDirs, 'ark_api_key'),
      speechAppId:
          _pick(_defineAppId, e['SPEECH_APP_ID'], secretsDirs, 'speech_app_id'),
      speechAccessToken: _pick(_defineToken, e['SPEECH_ACCESS_TOKEN'],
          secretsDirs, 'speech_access_token'),
    );
  }

  static String _pick(String defined, String? envValue,
      List<Directory> dirs, String fileName) {
    if (defined.isNotEmpty) return defined;
    if (envValue != null && envValue.trim().isNotEmpty) return envValue.trim();
    for (final dir in dirs) {
      final file = File('${dir.path}/$fileName');
      if (!file.existsSync()) continue;
      // 空白文件当作没有：多半是占位或误建，认下来会让凭据看起来齐全，
      // 一调用却 401，排查方向完全被带偏
      final value = file.readAsStringSync().trim();
      if (value.isNotEmpty) return value;
    }
    return '';
  }
}
