import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/diagnostics/tool_installer.dart';
import 'package:ishkafel/features/settings/tool_install_panel.dart';

/// 缺工具时给一个能点的按钮，而不是一句「请在终端执行……」。
void main() {
  ToolInstaller installer(List<String> output, int exitCode) => ToolInstaller(
        resolve: (name) => '/fake/$name',
        start: (_, _, _) async => _FakeProcess(output, exitCode),
      );

  Future<void> pump(WidgetTester tester, ToolInstaller inst,
          {VoidCallback? onInstalled}) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ToolInstallPanel(
              recipe: InstallRecipes.audioSeparator,
              installer: inst,
              onInstalled: onInstalled,
            ),
          ),
        ),
      ));

  testWidgets('开跑之前就把命令摆出来，连镜像源一起', (tester) async {
    await pump(tester, installer(const [], 0));
    expect(find.textContaining('uv tool install'), findsOneWidget);
    expect(find.textContaining('mirrors.tuna.tsinghua.edu.cn'), findsOneWidget,
        reason: '用的是哪个源属于「这条命令会做什么」的一部分，不能藏');
  });

  testWidgets('先说清楚要多久——1GB 的下载不能让人干等', (tester) async {
    await pump(tester, installer(const [], 0));
    expect(find.textContaining('1GB'), findsOneWidget);
    expect(find.textContaining('分钟'), findsOneWidget);
  });

  testWidgets('点了之后逐行显示输出，不是一个不说话的圈', (tester) async {
    await pump(tester, installer(const ['Resolving…', 'Downloading torch'], 0));
    await tester.tap(find.byKey(const Key('install-audio-separator')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('install-output')), findsOneWidget);
    expect(find.textContaining('Downloading torch'), findsOneWidget);
  });

  testWidgets('装完回调上层去重新体检', (tester) async {
    var installed = false;
    await pump(tester, installer(const ['ok'], 0),
        onInstalled: () => installed = true);
    await tester.tap(find.byKey(const Key('install-audio-separator')));
    await tester.pumpAndSettle();

    expect(installed, isTrue);
    expect(find.text('已装好'), findsOneWidget);
  });

  testWidgets('失败要给原始报文，按钮变成「重试」', (tester) async {
    await pump(tester, installer(const ['error: 连接超时'], 1));
    await tester.tap(find.byKey(const Key('install-audio-separator')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('install-failure')), findsOneWidget);
    expect(find.textContaining('连接超时'), findsWidgets);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('前置不在时说清楚该先装什么，而不是让它吐 command not found',
      (tester) async {
    final noUv = ToolInstaller(
      resolve: (_) => null,
      start: (_, _, _) async => throw StateError('不该起进程'),
    );
    await pump(tester, noUv);
    await tester.tap(find.byKey(const Key('install-audio-separator')));
    await tester.pumpAndSettle();

    expect(find.textContaining('uv'), findsWidgets);
    expect(find.textContaining('brew install uv'), findsOneWidget);
  });
}

class _FakeProcess implements Process {
  final List<String> _out;
  final int _code;

  _FakeProcess(this._out, this._code);

  @override
  Stream<List<int>> get stdout =>
      Stream.fromIterable(_out.map((l) => utf8.encode('$l\n')));

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  Future<int> get exitCode async => _code;

  @override
  int get pid => 1;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;

  @override
  IOSink get stdin => throw UnimplementedError();
}
