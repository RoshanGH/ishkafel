import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/miaoa/miaoa_account_service.dart';
import 'package:ishkafel/core/miaoa/miaoa_failure.dart';
import 'package:ishkafel/core/miaoa/miaoa_gateway.dart';

const _loggedInJson = '''
{
  "endpoint": "https://miaoa.example.com/api",
  "loggedIn": true,
  "projects": 42,
  "user": {
    "project": {"id": 173, "name": "卫仕洗衣液三组v2"},
    "tenant": {"tenantId": 19, "tenantName": "极创美奥", "accountName": "孟凡刚"},
    "userId": 11,
    "username": "13462890087"
  }
}
''';

MiaoaAccountService _service(String stdout, {int exitCode = 0, String stderr = ''}) =>
    MiaoaAccountService(gateway: MiaoaGateway(run: (_, _) async => ProcessResult(1, exitCode, stdout, stderr), binary: 'miaoa'));

void main() {
  group('账号信息的解析', () {
    test('读出登录状态、租户、当前项目与可选项目数', () async {
      final status = await _service(_loggedInJson).fetch();

      expect(status.loggedIn, isTrue);
      expect(status.tenantName, '极创美奥');
      expect(status.projectName, '卫仕洗衣液三组v2');
      expect(status.projectCount, 42);
      expect(status.endpoint, 'https://miaoa.example.com/api');
    });

    test('未登录时不编造租户和项目', () async {
      final status = await _service('{"loggedIn": false}').fetch();

      expect(status.loggedIn, isFalse);
      expect(status.tenantName, isNull);
      expect(status.projectName, isNull);
      expect(status.maskedAccount, isNull);
    });

    test('字段缺失不炸，缺什么就是 null', () async {
      // CLI 升级后换字段名 / 少给一层是常态，不该让整个设置页白屏
      final status = await _service('{"loggedIn": true, "user": {}}').fetch();

      expect(status.loggedIn, isTrue);
      expect(status.tenantName, isNull);
      expect(status.projectCount, isNull);
    });

    test('输出不是 JSON 时归类为未知失败，而不是抛原始解析异常', () async {
      final status = await _service('miaoa: command panicked').fetch();

      expect(status.loggedIn, isFalse);
      expect(status.failure, isNotNull);
      expect(status.failure!.kind, MiaoaFailureKind.unknown);
    });
  });

  group('账号标识必须脱敏', () {
    test('手机号只留前 3 后 4', () async {
      final status = await _service(_loggedInJson).fetch();

      expect(status.maskedAccount, '134****0087');
      expect(status.maskedAccount, isNot(contains('6289')),
          reason: '设置页会被截图、投屏、录屏；完整手机号属于个人信息，'
              '界面上任何位置都不该出现');
    });

    test('短标识也不整段暴露', () {
      expect(maskAccount('abc'), isNot('abc'));
      expect(maskAccount('abc'), startsWith('a'));
    });

    test('空字符串当作没有账号，不返回一串星号', () {
      expect(maskAccount(''), isNull);
      expect(maskAccount('   '), isNull);
    });
  });

  group('失败分类沿用既有的 miaoa 失败模型', () {
    test('未登录（401）给出登录引导，且不自动重试', () async {
      final status =
          await _service('', exitCode: 1, stderr: '401 Unauthorized').fetch();

      expect(status.loggedIn, isFalse);
      expect(status.failure!.kind, MiaoaFailureKind.unauthorized);
      expect(status.failure!.message, contains('miaoa auth login'));
    });

    test('CLI 没装时提示去装 miaoa，而不是「请重试」', () async {
      final service = MiaoaAccountService(gateway: MiaoaGateway(run: (_, _) async => throw const ProcessException('miaoa', []), binary: 'miaoa'));

      final status = await service.fetch();

      expect(status.failure!.kind, MiaoaFailureKind.cliMissing);
      expect(status.failure!.message, contains('miaoa'));
    });

    test('退出码非 0 但输出里明确写着未登录，仍按未登录处理', () async {
      final status = await _service('{"loggedIn": false}', exitCode: 1).fetch();

      expect(status.loggedIn, isFalse);
      expect(status.failure, isNull,
          reason: '「没登录」是正常状态不是故障，弹一条红色错误只会吓到用户');
    });
  });

  group('调用方式', () {
    test('用 --json 取结构化输出，不去解析人类可读文案', () async {
      final args = <List<String>>[];
      final service = MiaoaAccountService(gateway: MiaoaGateway(run: (_, a) async {
        args.add(a);
        return ProcessResult(1, 0, _loggedInJson, '');
      }, binary: 'miaoa'));

      await service.fetch();

      expect(args.single, containsAllInOrder(['auth', 'status']));
      expect(args.single, contains('--json'),
          reason: '人类可读输出的措辞随时会改，靠正则扒字段迟早会静默失效');
    });
  });
}
