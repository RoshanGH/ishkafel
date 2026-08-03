import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/ai_credentials.dart';

Directory _dirWith(Map<String, String> files) {
  final dir = Directory.systemTemp.createTempSync('ishkafel_cred_');
  addTearDown(() => dir.deleteSync(recursive: true));
  files.forEach((name, value) =>
      File('${dir.path}/$name').writeAsStringSync(value));
  return dir;
}

void main() {
  group('凭据可以放在多个目录里，按顺序找', () {
    test('第一个目录没有时落到第二个', () {
      final empty = _dirWith(const {});
      final data = _dirWith(const {
        'ark_api_key': 'ark-x',
        'speech_app_id': 'app-x',
        'speech_access_token': 'tok-x',
      });

      final creds =
          CredentialsLoader.load(env: const {}, secretsDirs: [empty, data]);

      expect(creds.isComplete, isTrue,
          reason: '从 Finder 启动时进程的工作目录是 /，项目里的 .secrets 永远'
              '找不到——只认一个目录等于打包出来的 app 一定没凭据');
      expect(creds.arkApiKey, 'ark-x');
    });

    test('靠前的目录优先', () {
      final first = _dirWith(const {'ark_api_key': 'first'});
      final second = _dirWith(const {
        'ark_api_key': 'second',
        'speech_app_id': 'app',
        'speech_access_token': 'tok',
      });

      final creds =
          CredentialsLoader.load(env: const {}, secretsDirs: [first, second]);

      expect(creds.arkApiKey, 'first');
      expect(creds.speechAppId, 'app',
          reason: '逐项回落：靠前目录只有一个文件时，其余项仍从后面的目录取');
    });

    test('目录不存在不抛异常，只是取不到', () {
      final creds = CredentialsLoader.load(
          env: const {}, secretsDirs: [Directory('/nowhere/at/all')]);

      expect(creds.isComplete, isFalse);
    });

    test('环境变量优先于文件', () {
      final data = _dirWith(const {'ark_api_key': 'from-file'});

      final creds = CredentialsLoader.load(
          env: const {'ARK_API_KEY': 'from-env'}, secretsDirs: [data]);

      expect(creds.arkApiKey, 'from-env');
    });

    test('文件里的空白被裁掉（编辑器保存时常带换行）', () {
      final data = _dirWith(const {'ark_api_key': '  ark-y\n'});

      final creds =
          CredentialsLoader.load(env: const {}, secretsDirs: [data]);

      expect(creds.arkApiKey, 'ark-y');
    });

    test('内容为空白的文件当作没有，继续往后找', () {
      final blank = _dirWith(const {'ark_api_key': '   \n'});
      final real = _dirWith(const {'ark_api_key': 'ark-z'});

      final creds =
          CredentialsLoader.load(env: const {}, secretsDirs: [blank, real]);

      expect(creds.arkApiKey, 'ark-z',
          reason: '空文件多半是占位或误建，把它当成有效值会让凭据看起来齐全'
              '却一调用就 401');
    });
  });
}
