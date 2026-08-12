import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/agent_skill/skill_installer.dart';
import 'package:ishkafel/features/settings/agent_skill_card.dart';
import 'package:path/path.dart' as p;

/// 「Agent 说明书」卡片。
///
/// 盯的是每种状态下用户看到什么、能点什么——尤其「有更新」不能跟「未安装」
/// 混成一句话：前者手上那份会把 Agent 带偏，后者只是还没有。
void main() {
  late Directory home;

  setUp(() => home = Directory.systemTemp.createTempSync('skill_card'));
  tearDown(() => home.deleteSync(recursive: true));

  SkillInstaller make({String version = '1.0.0'}) =>
      SkillInstaller.forCurrentUser(
          markdown: '# 手册\n', version: version, home: home.path);

  Future<void> pump(WidgetTester tester, SkillInstaller installer) =>
      tester.pumpWidget(ProviderScope(
        child: MaterialApp(
            home: Scaffold(
                body: SingleChildScrollView(
                    child: AgentSkillCard(installer: installer)))),
      ));

  testWidgets('没装：两家都显示未安装，按钮是「安装」，并说清装完在哪儿生效',
      (tester) async {
    await pump(tester, make());
    expect(find.text('Claude Code'), findsOneWidget);
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('未安装'), findsNWidgets(2));
    expect(find.text('安装'), findsOneWidget);
    expect(find.textContaining('任意文件夹都生效'), findsOneWidget);
    expect(find.textContaining('不用把这个项目的源码给谁'), findsOneWidget);
  });

  testWidgets('点安装 → 两家都装上，并告诉他下一句该怎么说', (tester) async {
    final installer = make();
    await pump(tester, installer);
    await tester.runAsync(() async {
      await tester.tap(find.text('安装'));
      while (!installer.inspect().allCurrent) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(find.text('已安装'), findsNWidgets(2));
    expect(find.textContaining('用 ishkafel 翻新这条片子'), findsWidgets);
    expect(find.text('移除'), findsOneWidget);
    for (final dir in ['.claude', '.codex']) {
      expect(
          File(p.join(home.path, dir, 'skills', 'ishkafel', 'SKILL.md'))
              .existsSync(),
          isTrue);
    }
  });

  testWidgets('app 升级过：说清旧说明书会把 Agent 带偏，按钮变成「更新」',
      (tester) async {
    await tester.runAsync(() => make(version: '1.0.0').install());
    await pump(tester, make(version: '2.0.0'));

    expect(find.text('有更新'), findsNWidgets(2));
    expect(find.text('更新'), findsOneWidget);
    expect(find.textContaining('照着旧文档去调新命令'), findsOneWidget);
  });

  testWidgets('只装了一家时分开显示，不含糊成一个总状态', (tester) async {
    await tester.runAsync(() => make().install());
    File(p.join(home.path, '.codex', 'skills', 'ishkafel', 'SKILL.md'))
        .deleteSync();

    await pump(tester, make());
    expect(find.text('已安装'), findsOneWidget);
    expect(find.text('未安装'), findsOneWidget);
  });
}
