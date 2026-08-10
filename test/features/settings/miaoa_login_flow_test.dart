import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/miaoa/miaoa_account_service.dart';
import 'package:ishkafel/core/miaoa/miaoa_auth_service.dart';
import 'package:ishkafel/features/settings/miaoa_login_sheet.dart';
import 'package:ishkafel/features/settings/sections/account_section.dart';
import 'package:ishkafel/features/settings/settings_providers.dart';

/// 在设置里登录 miaoa。
///
/// 换一台电脑、或者换一个人用这个包，都要在本机登录一次——登录态跟着 miaoa
/// CLI 走，不在安装包里。以前这一步要用户自己开终端敲命令，那不是商业软件
/// 该有的样子。
void main() {
  /// 按调用顺序回放 CLI 的响应，并记下每次的参数
  ({MiaoaAuthService service, List<List<String>> calls}) fakeAuth(
    List<({int code, String out, String err})> responses,
  ) {
    final calls = <List<String>>[];
    var i = 0;
    return (
      calls: calls,
      service: MiaoaAuthService(
        resolveBinary: () => 'miaoa',
        run: (bin, args) async {
          calls.add(args);
          final r =
              responses[i < responses.length ? i++ : responses.length - 1];
          return ProcessResult(0, r.code, r.out, r.err);
        },
      ),
    );
  }

  Future<void> pumpSettings(
    WidgetTester tester, {
    required MiaoaAccountStatus status,
    MiaoaAuthService? auth,
  }) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        miaoaAccountProvider.overrideWith((ref) async => status),
        miaoaAuthServiceProvider.overrideWithValue(auth),
      ],
      child: const MaterialApp(home: Scaffold(body: AccountSection())),
    ));
    await tester.pumpAndSettle();
  }

  const loggedOut = MiaoaAccountStatus(loggedIn: false);
  const loggedIn = MiaoaAccountStatus(
      loggedIn: true, maskedAccount: '138****5678', tenantName: '某租户');

  group('未登录时给的是一个能点的按钮，不是一条要去终端敲的命令', () {
    testWidgets('接上了登录服务就摆按钮', (tester) async {
      await pumpSettings(tester,
          status: loggedOut, auth: fakeAuth(const []).service);
      expect(find.byKey(const Key('settings-login')), findsOneWidget);
      expect(find.byKey(const Key('settings-copy-login-command')), findsNothing,
          reason: '有按钮就不该再教用户敲命令');
    });

    testWidgets('没接上时退回终端引导，而不是摆一个点了没反应的按钮', (tester) async {
      await pumpSettings(tester, status: loggedOut, auth: null);
      expect(find.byKey(const Key('settings-login')), findsNothing);
      expect(
          find.byKey(const Key('settings-copy-login-command')), findsOneWidget);
    });

    testWidgets('说清楚登录态是跟着这台电脑走的', (tester) async {
      await pumpSettings(tester,
          status: loggedOut, auth: fakeAuth(const []).service);
      expect(find.textContaining('换一台电脑要再登一次'), findsOneWidget);
    });
  });

  group('两步登录', () {
    testWidgets('手机号没填够 11 位时「获取验证码」点不了', (tester) async {
      final fake = fakeAuth(const []);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: MiaoaLoginSheet(service: fake.service))));
      await tester.enterText(find.byKey(const Key('login-phone')), '138');
      await tester.pump();
      final button =
          tester.widget<FilledButton>(find.byKey(const Key('login-primary')));
      expect(button.onPressed, isNull);
      expect(fake.calls, isEmpty);
    });

    testWidgets('发码成功后才出现验证码输入框', (tester) async {
      final fake = fakeAuth([(code: 0, out: '{"sent":true}', err: '')]);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: MiaoaLoginSheet(service: fake.service))));
      expect(find.byKey(const Key('login-code')), findsNothing,
          reason: '一上来摆两个空框，用户不知道该先填哪个');

      await tester.enterText(
          find.byKey(const Key('login-phone')), '13812345678');
      await tester.pump();
      await tester.tap(find.byKey(const Key('login-primary')));
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('login-code')), findsOneWidget);
      expect(fake.calls.single, containsAllInOrder(['--phone', '13812345678']));
    });

    testWidgets('填码登录成功后关掉弹窗并回报成功', (tester) async {
      final fake = fakeAuth([
        (code: 0, out: '{"sent":true}', err: ''),
        (code: 0, out: '{"loggedIn":true}', err: ''),
      ]);
      bool? outcome;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  outcome = await MiaoaLoginSheet.show(context, fake.service),
              child: const Text('开'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('开'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(const Key('login-phone')), '13812345678');
      await tester.pump();
      await tester.tap(find.byKey(const Key('login-primary')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('login-code')), '123456');
      await tester.pump();
      await tester.tap(find.byKey(const Key('login-primary')));
      await tester.pumpAndSettle();

      expect(outcome, isTrue);
      expect(find.byKey(const Key('login-phone')), findsNothing, reason: '该关掉了');
      expect(fake.calls[1], containsAllInOrder(['--code', '123456']));
    });

    testWidgets('验证码错了留在原地说清楚，不把人踢回第一步', (tester) async {
      final fake = fakeAuth([
        (code: 0, out: '{"sent":true}', err: ''),
        (code: 1, out: '', err: 'invalid verification code'),
      ]);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: MiaoaLoginSheet(service: fake.service))));
      await tester.enterText(
          find.byKey(const Key('login-phone')), '13812345678');
      await tester.pump();
      await tester.tap(find.byKey(const Key('login-primary')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('login-code')), '000000');
      await tester.pump();
      await tester.tap(find.byKey(const Key('login-primary')));
      await tester.pumpAndSettle();

      expect(find.textContaining('验证码不正确'), findsOneWidget);
      expect(find.byKey(const Key('login-code')), findsOneWidget,
          reason: '还在第二步，改一下重填就行');
    });

    testWidgets('重新获取有冷却——短信有成本，也别让人狂点', (tester) async {
      final fake = fakeAuth([(code: 0, out: '{"sent":true}', err: '')]);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: MiaoaLoginSheet(
                  service: fake.service, resendCooldownSeconds: 3))));
      await tester.enterText(
          find.byKey(const Key('login-phone')), '13812345678');
      await tester.pump();
      await tester.tap(find.byKey(const Key('login-primary')));
      await tester.pump();
      await tester.pump();

      final resend =
          tester.widget<TextButton>(find.byKey(const Key('login-resend')));
      expect(resend.onPressed, isNull);
      expect(find.textContaining('重新获取（'), findsOneWidget);

      await tester.pump(const Duration(seconds: 4));
      final after =
          tester.widget<TextButton>(find.byKey(const Key('login-resend')));
      expect(after.onPressed, isNotNull);
    });
  });

  group('退出登录', () {
    testWidgets('是破坏性操作，要先确认', (tester) async {
      final fake = fakeAuth([(code: 0, out: '', err: '')]);
      await pumpSettings(tester, status: loggedIn, auth: fake.service);
      await tester.tap(find.byKey(const Key('settings-logout')));
      await tester.pumpAndSettle();

      expect(find.text('退出 miaoa 登录？'), findsOneWidget);
      expect(fake.calls, isEmpty, reason: '还没确认就不该真的退');

      await tester.tap(find.byKey(const Key('settings-logout-confirm')));
      await tester.pumpAndSettle();
      expect(fake.calls.single, containsAllInOrder(['auth', 'logout']));
    });

    testWidgets('确认框要说清楚代价，以及什么不受影响', (tester) async {
      await pumpSettings(
          tester, status: loggedIn, auth: fakeAuth(const []).service);
      await tester.tap(find.byKey(const Key('settings-logout')));
      await tester.pumpAndSettle();
      expect(find.textContaining('无法检索候选素材'), findsOneWidget);
      expect(find.textContaining('已经下载到本地的素材不受影响'), findsOneWidget);
    });

    testWidgets('退出失败不能装作退了', (tester) async {
      final fake = fakeAuth([(code: 1, out: '', err: 'connection refused')]);
      await pumpSettings(tester, status: loggedIn, auth: fake.service);
      await tester.tap(find.byKey(const Key('settings-logout')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-logout-confirm')));
      await tester.pumpAndSettle();
      expect(find.textContaining('连接 miaoa 失败'), findsOneWidget);
    });

    testWidgets('没接登录服务时不显示退出入口', (tester) async {
      await pumpSettings(tester, status: loggedIn, auth: null);
      expect(find.byKey(const Key('settings-logout')), findsNothing);
    });
  });
}
