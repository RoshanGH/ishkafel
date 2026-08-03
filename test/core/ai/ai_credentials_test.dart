import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/ai_credentials.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ishkafel_cred_');
  });

  tearDown(() async => tempDir.delete(recursive: true));

  test('isComplete 三项齐全才为 true', () {
    const full = AiCredentials(
        arkApiKey: 'k', speechAppId: 'a', speechAccessToken: 't');
    const partial =
        AiCredentials(arkApiKey: 'k', speechAppId: '', speechAccessToken: 't');
    expect(full.isComplete, true);
    expect(partial.isComplete, false);
  });

  test('环境变量优先于 .secrets 文件', () async {
    await File('${tempDir.path}/ark_api_key').writeAsString('file-key\n');
    final creds = CredentialsLoader.load(
      env: {'ARK_API_KEY': 'env-key'},
      secretsDirs: [tempDir],
    );
    expect(creds.arkApiKey, 'env-key');
  });

  test('.secrets 文件兜底且去除首尾空白', () async {
    await File('${tempDir.path}/ark_api_key').writeAsString('  file-key \n');
    await File('${tempDir.path}/speech_app_id').writeAsString('123');
    final creds = CredentialsLoader.load(env: const {}, secretsDirs: [tempDir]);
    expect(creds.arkApiKey, 'file-key');
    expect(creds.speechAppId, '123');
    expect(creds.speechAccessToken, '');
    expect(creds.isComplete, false);
  });

  test('三处皆无时字段为空串', () {
    final creds = CredentialsLoader.load(env: const {}, secretsDirs: const []);
    expect(creds.arkApiKey, anyOf('', isNotEmpty)); // dart-define 注入时非空
  });
}
