import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/miaoa/miaoa_auth_service.dart';
import 'package:ishkafel/core/miaoa/miaoa_failure.dart';
import 'package:ishkafel/core/miaoa/miaoa_gateway.dart';

/// 在 app 里登录 miaoa。
///
/// **凭据仍然由 CLI 存，我们一个字节都不留**：这里做的只是把手机号和验证码
/// 转发给 `miaoa auth login` 跑一次。自己再存一份 token 的话，就会有两份登录
/// 态——app 说「已登录」而 CLI 那边早过期，一检索就 401。
void main() {
  late List<List<String>> calls;

  MiaoaAuthService serviceReturning(
    List<({int code, String out, String err})> responses,
  ) {
    calls = [];
    var i = 0;
    return MiaoaAuthService(gateway: MiaoaGateway(run: (bin, args) async {
        calls.add(args);
        final r = responses[i < responses.length ? i++ : responses.length - 1];
        return ProcessResult(0, r.code, r.out, r.err);
      }, binary: 'miaoa'));
  }

  MiaoaAuthService serviceThrowing(Object error) {
    calls = [];
    return MiaoaAuthService(gateway: MiaoaGateway(run: (bin, args) async {
        calls.add(args);
        throw error;
      }, binary: 'miaoa'));
  }

  group('手机号在进 CLI 之前就要挡住', () {
    test('位数不对直接说清楚，不白跑一趟子进程', () async {
      final service = serviceReturning([(code: 0, out: '{}', err: '')]);
      final result = await service.requestCode(phone: '1381234');
      expect(result.ok, isFalse);
      expect(result.message, contains('11 位'));
      expect(calls, isEmpty, reason: '本地就能判的错不该发出去');
    });

    test('夹了空格和横杠也认——用户从通讯录粘过来就是这样', () async {
      final service = serviceReturning([(code: 0, out: '{}', err: '')]);
      final result = await service.requestCode(phone: ' 138 1234-5678 ');
      expect(result.ok, isTrue);
      expect(calls.single, containsAllInOrder(['--phone', '13812345678']));
    });

    test('非数字不放行', () async {
      final service = serviceReturning([(code: 0, out: '{}', err: '')]);
      final result = await service.requestCode(phone: '138abcd5678');
      expect(result.ok, isFalse);
      expect(calls, isEmpty);
    });
  });

  group('第一步：发验证码', () {
    test('命令形态就是 CLI 文档里那条，并要 json', () async {
      final service = serviceReturning([(code: 0, out: '{"sent":true}', err: '')]);
      await service.requestCode(phone: '13812345678');
      expect(calls.single, [
        'auth',
        'login',
        '--phone',
        '13812345678',
        '--country-code',
        '+86',
        '--json',
      ]);
    });

    test('CLI 报错时按成因分类给人话，不把原始报文摊给用户', () async {
      final service = serviceReturning([
        (code: 1, out: '', err: 'rate limit exceeded, retry after 60s'),
      ]);
      final result = await service.requestCode(phone: '13812345678');
      expect(result.ok, isFalse);
      expect(result.message, isNotEmpty);
      expect(result.message, isNot(contains('rate limit')));
    });

    test('CLI 没装：说去装，而不是说登录失败', () async {
      final service = serviceThrowing(
          const ProcessException('miaoa', ['auth'], 'not found'));
      final result = await service.requestCode(phone: '13812345678');
      expect(result.ok, isFalse);
      expect(result.kind, MiaoaFailureKind.cliMissing);
      expect(result.message, contains('miaoa'));
    });
  });

  group('第二步：填码登录', () {
    test('手机号与验证码一起交给 CLI', () async {
      final service =
          serviceReturning([(code: 0, out: '{"loggedIn":true}', err: '')]);
      final result =
          await service.completeLogin(phone: '13812345678', code: '123456');
      expect(result.ok, isTrue);
      expect(calls.single, containsAllInOrder(
          ['--phone', '13812345678', '--code', '123456']));
    });

    test('空验证码本地挡下', () async {
      final service = serviceReturning([(code: 0, out: '{}', err: '')]);
      final result =
          await service.completeLogin(phone: '13812345678', code: '  ');
      expect(result.ok, isFalse);
      expect(calls, isEmpty);
    });

    test('验证码错：说验证码错，别说成登录失效让人去重新登录', () async {
      final service = serviceReturning([
        (code: 1, out: '', err: 'invalid verification code'),
      ]);
      final result =
          await service.completeLogin(phone: '13812345678', code: '000000');
      expect(result.ok, isFalse);
      expect(result.message, contains('验证码'));
    });

    test('验证码过期也要单独说——重发一次就好，不是账号有问题', () async {
      final service = serviceReturning([
        (code: 1, out: '', err: 'verification code expired'),
      ]);
      final result =
          await service.completeLogin(phone: '13812345678', code: '000000');
      expect(result.ok, isFalse);
      expect(result.message, contains('过期'));
      expect(result.message, contains('重新获取'));
    });

    test('退出码 0 但 CLI 说没登录成功：算失败，不能报喜', () async {
      final service = serviceReturning([
        (code: 0, out: '{"loggedIn":false,"error":"something"}', err: ''),
      ]);
      final result =
          await service.completeLogin(phone: '13812345678', code: '123456');
      expect(result.ok, isFalse);
    });
  });

  group('退出登录', () {
    test('调 CLI 的 logout，由它清掉本地凭据', () async {
      final service = serviceReturning([(code: 0, out: '', err: '')]);
      final result = await service.logout();
      expect(result.ok, isTrue);
      expect(calls.single, containsAllInOrder(['auth', 'logout']));
    });

    test('登出失败也要说清楚——否则用户以为已经退了', () async {
      final service =
          serviceReturning([(code: 1, out: '', err: 'connection refused')]);
      final result = await service.logout();
      expect(result.ok, isFalse);
      expect(result.kind, MiaoaFailureKind.network);
    });
  });

  group('手机号和验证码绝不能落在任何地方', () {
    test('结果对象里不带手机号原文', () async {
      final service = serviceReturning([
        (code: 1, out: '', err: 'invalid verification code'),
      ]);
      final result =
          await service.completeLogin(phone: '13812345678', code: '123456');
      expect(result.message, isNot(contains('13812345678')));
      expect(result.message, isNot(contains('123456')));
    });
  });
}
