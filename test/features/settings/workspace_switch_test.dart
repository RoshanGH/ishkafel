import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/miaoa/miaoa_account_service.dart';
import 'package:ishkafel/core/miaoa/miaoa_auth_service.dart';
import 'package:ishkafel/features/settings/sections/account_section.dart';
import 'package:ishkafel/features/settings/settings_providers.dart';
import 'package:ishkafel/features/settings/workspace_picker_sheet.dart';

/// 选企业 / 选项目。
///
/// 这一组盯的是一条**真机上撞过的静默失败链**：
///
///   登录后没选企业 → 落在默认企业上 → 新建任务选不到标签组
///   → AI 没有受控词表、打不出标签 → 挑替换素材时「没有标签」
///
/// 中间没有任何一步会报错。用户看到的只是最后那个「没有标签」，
/// 而真正的原因在四步之前。
void main() {
  const tenantsJson =
      '{"tenants":[{"tenantId":19,"tenantName":"极创美奥"},'
      '{"tenantId":4,"tenantName":"演示专用企业"}]}';
  const projectsJson =
      '{"records":[{"id":186,"name":"DDS便携消毒AI组","isEnabled":true},'
      '{"id":9,"name":"已停用的项目","isEnabled":false}]}';

  ({MiaoaAuthService service, List<List<String>> calls}) fake(
    Map<String, ({int code, String out})> byCommand,
  ) {
    final calls = <List<String>>[];
    return (
      calls: calls,
      service: MiaoaAuthService(
        resolveBinary: () => 'miaoa',
        run: (bin, args) async {
          calls.add(args);
          final hit = byCommand[args.take(2).join(' ')];
          return ProcessResult(
              0, hit?.code ?? 0, hit?.out ?? '{}', hit == null ? '' : '');
        },
      ),
    );
  }

  group('解析 CLI 的输出', () {
    test('企业列表认得出 tenantId / tenantName', () async {
      final f = fake({'tenant list': (code: 0, out: tenantsJson)});
      final list = await f.service.listTenants(currentId: 19);
      expect(list.ok, isTrue);
      expect(list.items.map((t) => t.name), ['极创美奥', '演示专用企业']);
      expect(list.items.first.current, isTrue);
      expect(list.items.last.current, isFalse);
    });

    test('停用的项目不列出来——点了也切不过去', () async {
      final f = fake({'project list': (code: 0, out: projectsJson)});
      final list = await f.service.listProjects();
      expect(list.items.map((p) => p.name), ['DDS便携消毒AI组']);
    });

    test('切换命令带上 id', () async {
      final f = fake({'tenant select': (code: 0, out: '{}')});
      final result = await f.service.selectTenant(19);
      expect(result.ok, isTrue);
      expect(f.calls.single, containsAllInOrder(['tenant', 'select', '19']));
    });

    test('读不到时给的是人话，不是原始报文', () async {
      final f = fake({'tenant list': (code: 1, out: 'error: 401 unauthorized')});
      final list = await f.service.listTenants();
      expect(list.ok, isFalse);
      expect(list.failure, isNotEmpty);
      expect(list.failure, isNot(contains('401')));
    });
  });

  group('选择器', () {
    Future<void> pump(WidgetTester tester, MiaoaAuthService service,
            {bool dismissible = true}) =>
        tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: WorkspacePickerSheet(
              title: '选择企业',
              description: '标签组是按企业分的',
              load: () => service.listTenants(currentId: 19),
              select: service.selectTenant,
              dismissible: dismissible,
            ),
          ),
        ));

    testWidgets('把可选的都列出来，并标出当前在哪个', (tester) async {
      final f = fake({'tenant list': (code: 0, out: tenantsJson)});
      await pump(tester, f.service);
      await tester.pumpAndSettle();
      expect(find.text('极创美奥'), findsOneWidget);
      expect(find.text('演示专用企业'), findsOneWidget);
      expect(find.text('当前'), findsOneWidget);
    });

    testWidgets('点一个就切过去', (tester) async {
      final f = fake({
        'tenant list': (code: 0, out: tenantsJson),
        'tenant select': (code: 0, out: '{}'),
      });
      await pump(tester, f.service);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('workspace-4')));
      await tester.pumpAndSettle();
      expect(f.calls.last, containsAllInOrder(['tenant', 'select', '4']));
    });

    testWidgets('切失败时留在原地说清楚，不假装切成了', (tester) async {
      final f = fake({
        'tenant list': (code: 0, out: tenantsJson),
        'tenant select': (code: 1, out: 'error: forbidden'),
      });
      await pump(tester, f.service);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('workspace-4')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('workspace-error')), findsOneWidget);
      expect(find.byKey(const Key('workspace-list')), findsOneWidget);
    });

    testWidgets('登录流程里不给「取消」——跳过就是把人留在不确定的上下文里',
        (tester) async {
      final f = fake({'tenant list': (code: 0, out: tenantsJson)});
      await pump(tester, f.service, dismissible: false);
      await tester.pumpAndSettle();
      expect(find.text('取消'), findsNothing);
      expect(find.text('重新读取'), findsOneWidget, reason: '读失败时总得有条出路');
    });

    testWidgets('一个可选项都没有时说清楚该找谁', (tester) async {
      final f = fake({'tenant list': (code: 0, out: '{"tenants":[]}')});
      await pump(tester, f.service);
      await tester.pumpAndSettle();
      expect(find.textContaining('联系 miaoa 管理员'), findsOneWidget);
    });
  });

  group('设置页', () {
    testWidgets('企业与项目各有一个「切换」入口', (tester) async {
      final f = fake({'tenant list': (code: 0, out: tenantsJson)});
      await tester.pumpWidget(ProviderScope(
        overrides: [
          miaoaAccountProvider.overrideWith((ref) async =>
              const MiaoaAccountStatus(
                  loggedIn: true,
                  maskedAccount: '138****5678',
                  tenantName: '极创美奥',
                  projectName: '植源AI')),
          miaoaAuthServiceProvider.overrideWithValue(f.service),
        ],
        child: const MaterialApp(home: Scaffold(body: AccountSection())),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-switch-tenant')), findsOneWidget);
      expect(find.byKey(const Key('settings-switch-project')), findsOneWidget);
      expect(find.text('企业'), findsOneWidget);
    });

    testWidgets('没接登录服务时不显示切换入口——那时只能去终端改', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          miaoaAccountProvider.overrideWith((ref) async =>
              const MiaoaAccountStatus(loggedIn: true, tenantName: '极创美奥')),
          miaoaAuthServiceProvider.overrideWithValue(null),
        ],
        child: const MaterialApp(home: Scaffold(body: AccountSection())),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-switch-tenant')), findsNothing);
    });
  });
}
