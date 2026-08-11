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

    test('停用的项目由**服务端**滤掉，客户端不再自己动手', () async {
      // 在客户端滤会让每页拿到的条数参差不齐，翻页立刻就不准了
      // ——真机上 69 个项目只显示 10 个，就是这么来的
      final f = fake({'project list': (code: 0, out: projectsJson)});
      await f.service.listProjects();
      expect(f.calls.single, contains('--enabled-only'));
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

  group('项目列表要拉全——真机上 69 个只显示了 10 个', () {
    /// 按 page 参数回放分页数据
    ({MiaoaAuthService service, List<List<String>> calls}) paged(int total) {
      final calls = <List<String>>[];
      return (
        calls: calls,
        service: MiaoaAuthService(
          resolveBinary: () => 'miaoa',
          run: (bin, args) async {
            calls.add(args);
            final page =
                int.parse(args[args.indexOf('--page') + 1]);
            final size = int.parse(args[args.indexOf('--page-size') + 1]);
            final from = (page - 1) * size;
            final records = [
              for (var i = from; i < total && i < from + size; i++)
                '{"id":${i + 1},"name":"项目${i + 1}","isEnabled":true}',
            ];
            return ProcessResult(
                0, 0, '{"total":$total,"records":[${records.join(',')}]}', '');
          },
        ),
      );
    }

    test('一页装不下就接着翻，直到拿全', () async {
      final f = paged(69);
      final list = await f.service.listProjects();
      expect(list.items, hasLength(69));
      expect(f.calls.length, 1, reason: 'page-size 给足时一页就够，不该白跑第二趟');
    });

    test('总数超过一页时真的翻页', () async {
      final f = paged(250);
      final list = await f.service.listProjects();
      expect(list.items, hasLength(250));
      expect(f.calls.length, greaterThan(1));
      expect(f.calls[1], containsAllInOrder(['--page', '2']));
    });

    test('停用的交给服务端滤——在客户端滤会让每页条数参差，翻页立刻不准', () async {
      final f = paged(5);
      await f.service.listProjects();
      expect(f.calls.single, contains('--enabled-only'));
    });

    test('翻到一半断了，先把已经拿到的给用户用', () async {
      var call = 0;
      final service = MiaoaAuthService(
        resolveBinary: () => 'miaoa',
        run: (bin, args) async {
          call++;
          if (call == 1) {
            final records = [
              for (var i = 0; i < 100; i++)
                '{"id":${i + 1},"name":"项目${i + 1}","isEnabled":true}',
            ];
            return ProcessResult(
                0, 0, '{"total":250,"records":[${records.join(',')}]}', '');
          }
          return ProcessResult(0, 1, '', 'error: connection reset');
        },
      );
      final list = await service.listProjects();
      expect(list.items, hasLength(100));
      expect(list.ok, isTrue, reason: '拿到一部分总比什么都没有强');
    });

    test('第一页就失败才算失败', () async {
      final f = fake({'project list': (code: 1, out: 'error: 401')});
      final list = await f.service.listProjects();
      expect(list.ok, isFalse);
    });
  });

  group('几十个的时候要能搜', () {
    testWidgets('超过阈值才出搜索框', (tester) async {
      final many = [
        for (var i = 0; i < 30; i++)
          '{"id":$i,"name":"项目$i","isEnabled":true}',
      ];
      final f = fake({
        'project list': (code: 0, out: '{"total":30,"records":[${many.join(',')}]}')
      });
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkspacePickerSheet(
            title: '切换项目',
            description: '',
            load: f.service.listProjects,
            select: f.service.switchProject,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('workspace-search')), findsOneWidget);

      await tester.enterText(find.byKey(const Key('workspace-search')), '项目29');
      await tester.pumpAndSettle();
      // 输入框本身也渲染成一个 Text，所以列表里那条 + 输入框 = 2
      expect(find.text('项目29'), findsNWidgets(2));
      expect(find.text('项目1'), findsNothing);
    });

    testWidgets('只有两三个时不摆搜索框——那只是噪音', (tester) async {
      final f = fake({'tenant list': (code: 0, out: tenantsJson)});
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkspacePickerSheet(
            title: '切换企业',
            description: '',
            load: f.service.listTenants,
            select: f.service.selectTenant,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('workspace-search')), findsNothing);
    });

    testWidgets('搜不到时说清楚搜的是什么', (tester) async {
      final many = [
        for (var i = 0; i < 30; i++)
          '{"id":$i,"name":"项目$i","isEnabled":true}',
      ];
      final f = fake({
        'project list': (code: 0, out: '{"total":30,"records":[${many.join(',')}]}')
      });
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkspacePickerSheet(
            title: '切换项目',
            description: '',
            load: f.service.listProjects,
            select: f.service.switchProject,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('workspace-search')), '不存在的东西');
      await tester.pumpAndSettle();
      expect(find.textContaining('没有匹配'), findsOneWidget);
    });
  });

  group('登录了却没有企业——真机上同事卡在这里', () {
    testWidgets('账号区顶上一条醒目的警告，并且当场能选', (tester) async {
      final f = fake({'tenant list': (code: 0, out: tenantsJson)});
      await tester.pumpWidget(ProviderScope(
        overrides: [
          // 这就是同事截图里的状态：已登录、租户为空、项目 0 个
          miaoaAccountProvider.overrideWith((ref) async =>
              const MiaoaAccountStatus(
                  loggedIn: true,
                  maskedAccount: '173****8350',
                  tenantName: null,
                  projectCount: 0)),
          miaoaAuthServiceProvider.overrideWithValue(f.service),
        ],
        child: const MaterialApp(home: Scaffold(body: AccountSection())),
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('还没有选择企业'), findsOneWidget);
      expect(find.textContaining('什么都干不了'), findsOneWidget,
          reason: '要说清后果，不能只说「未选择」');
      expect(find.byKey(const Key('settings-choose-tenant')), findsOneWidget);
    });

    testWidgets('已经有企业时不出这条警告——别拿噪音占地方', (tester) async {
      final f = fake({'tenant list': (code: 0, out: tenantsJson)});
      await tester.pumpWidget(ProviderScope(
        overrides: [
          miaoaAccountProvider.overrideWith((ref) async =>
              const MiaoaAccountStatus(loggedIn: true, tenantName: '极创美奥')),
          miaoaAuthServiceProvider.overrideWithValue(f.service),
        ],
        child: const MaterialApp(home: Scaffold(body: AccountSection())),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('还没有选择企业'), findsNothing);
    });

    testWidgets('没接登录服务时给出终端命令，而不是一个点不了的按钮', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          miaoaAccountProvider.overrideWith((ref) async =>
              const MiaoaAccountStatus(loggedIn: true, tenantName: null)),
          miaoaAuthServiceProvider.overrideWithValue(null),
        ],
        child: const MaterialApp(home: Scaffold(body: AccountSection())),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-choose-tenant')), findsNothing);
      expect(find.textContaining('miaoa tenant select'), findsOneWidget);
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
