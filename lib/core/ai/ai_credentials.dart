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

/// 三级装载：--dart-define（打包注入）→ 环境变量 → .secrets 开发文件
class CredentialsLoader {
  static const _defineArk = String.fromEnvironment('ARK_API_KEY');
  static const _defineAppId = String.fromEnvironment('SPEECH_APP_ID');
  static const _defineToken = String.fromEnvironment('SPEECH_ACCESS_TOKEN');

  static AiCredentials load({Map<String, String>? env, Directory? devSecretsDir}) {
    final e = env ?? Platform.environment;
    return AiCredentials(
      arkApiKey: _pick(_defineArk, e['ARK_API_KEY'], devSecretsDir, 'ark_api_key'),
      speechAppId:
          _pick(_defineAppId, e['SPEECH_APP_ID'], devSecretsDir, 'speech_app_id'),
      speechAccessToken: _pick(_defineToken, e['SPEECH_ACCESS_TOKEN'],
          devSecretsDir, 'speech_access_token'),
    );
  }

  static String _pick(
      String defined, String? envValue, Directory? dir, String fileName) {
    if (defined.isNotEmpty) return defined;
    if (envValue != null && envValue.trim().isNotEmpty) return envValue.trim();
    if (dir != null) {
      final file = File('${dir.path}/$fileName');
      if (file.existsSync()) return file.readAsStringSync().trim();
    }
    return '';
  }
}
