import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/agent_skill/skill_installer.dart';
import 'package:ishkafel/features/settings/agent_skill_card.dart';

/// 「Agent 说明书」卡片。
///
/// 只有一种分发方式：把全文给 Agent，让它自己装。不替任何一家写技能目录
/// ——技能目录每家都不一样，替两家装、别家不管，反而让人以为只支持那两家。
void main() {
  late Directory home;

  setUp(() => home = Directory.systemTemp.createTempSync('skill_card'));
  tearDown(() => home.deleteSync(recursive: true));

  SkillInstaller make() => SkillInstaller.forCurrentUser(
      markdown: '# 手册\n', version: '1.0.0', home: home.path);

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(ProviderScope(
        child: MaterialApp(
            home: Scaffold(
                body: SingleChildScrollView(
                    child: AgentSkillCard(installer: make())))),
      ));

  testWidgets('只有复制全文与存成文件，没有「安装」按钮', (tester) async {
    await pump(tester);
    expect(find.text('复制全文'), findsOneWidget);
    expect(find.text('存成文件'), findsOneWidget);
    expect(find.text('安装'), findsNothing,
        reason: '替两家写技能目录、别家不管，会让人以为只支持那两家');
  });

  testWidgets('说清用法：粘给任何 Agent 让它自己装', (tester) async {
    await pump(tester);
    expect(find.textContaining('让它自己装成技能'), findsOneWidget);
  });

  testWidgets('复制出去的是带 frontmatter 的完整说明书', (tester) async {
    final text = make().markdownForSharing;
    expect(text, startsWith('---\n'));
    expect(text, contains('name: ishkafel'));
    expect(text, contains('# 手册'), reason: '正文要在里面');
  });

  testWidgets('复制后告诉用户下一句怎么跟 Agent 说', (tester) async {
    // Clipboard 走平台通道，要给测试装一个假的收信端，否则 await 永远不回来
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async => null);
    await pump(tester);
    await tester.tap(find.text('复制全文'));
    await tester.pumpAndSettle();
    expect(find.textContaining('把这份技能装给你自己'), findsOneWidget);
  });
}
