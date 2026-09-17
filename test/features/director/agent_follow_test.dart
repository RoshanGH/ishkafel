import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/settings/settings_providers.dart';
import 'package:ishkafel/features/tasks/task_list_controller.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/storage/agent_presence.dart';
import 'package:ishkafel/core/storage/task_repository.dart';
import 'package:ishkafel/features/agent/visual_pace.dart';
import 'package:ishkafel/features/director/director_page.dart';

/// Agent 干活时，这块屏要跟着它走——用户原话：
/// 「它选中第 10 行，那就跟人一样把第 10 行放到界面中间；它去调某一镜的
/// 时长，那个面板就打开，跟人自己点开去调的时候是一样的。」
class _MemoryRepo implements TaskRepository {
  final _store = <String, RenewTask>{};
  @override
  Future<List<RenewTask>> findAll() async => _store.values.toList();
  @override
  Future<RenewTask?> findById(String id) async => _store[id];
  @override
  Future<void> save(RenewTask task) async => _store[task.id] = task;
  @override
  Future<void> delete(String id) async => _store.remove(id);
}

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('agent_gui'));
  tearDown(() => dir.delete(recursive: true));

  ScriptDoc docWith(int lines) => ScriptDoc([
        for (var i = 0; i < lines; i++)
          ScriptLine.create(text: '第 ${i + 1} 句台词').withShots([
            LineShot(materialId: 100 + i, name: 's$i', durationMs: 9000),
          ]),
      ]);

  RenewTask taskWith(ScriptDoc doc) => RenewTask(
        id: 't1',
        seq: 1,
        name: '脚本',
        sourcePath: null,
        script: doc,
        status: RenewTaskStatus.ready,
        createdAt: DateTime.utc(2026, 8, 26),
        updatedAt: DateTime.utc(2026, 8, 26),
      );

  Future<void> pump(WidgetTester tester, _MemoryRepo repo) async {
    await repo.save(taskWith(docWith(20)));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        taskRepositoryProvider.overrideWithValue(repo),
        dataDirProvider.overrideWithValue(dir),
      ],
      child: MaterialApp(
        home: DirectorPage(task: taskWith(docWith(20)), playbackFactory: () => null),
      ),
    ));
    await tester.pumpAndSettle();
  }

  void report(AgentPresence p) =>
      writeAgentPresence(dataDir: dir, taskId: 't1', presence: p);

  testWidgets('Agent 在场：横幅说清是谁、正在做什么', (tester) async {
    final repo = _MemoryRepo();
    await pump(tester, repo);

    report(AgentPresence(
        holder: 'Agent', at: DateTime.now(), action: '正在给第 10 句挑镜头'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    expect(find.textContaining('正在这条任务上干活'), findsOneWidget);
    expect(find.text('正在给第 10 句挑镜头'), findsOneWidget,
        reason: '人在旁边看的是过程——它现在在干什么必须写出来');
  });

  /// **这不是「没有权限」**——软件里已经没有任何一把锁，Agent 随时写得进
  /// 这条任务，人也随时能自己上手。但这一页把整份脚本捧在内存里、定时整份
  /// 落盘：Agent 正在一行行写盘的同时人在这儿打字，下一次「跟盘」会把他刚
  /// 打的字冲掉，而他看不见。所以这一刻先拦一下，**出路就在眼前那个按钮上**。
  ///
  /// **而那句提示必须说实话**：点「我来接手」只是让这一页不再跟随它，
  /// Agent 那条命令照样在跑。软件不提供「停掉 Agent」这个能力——人要停它，
  /// 去 Agent 那头说。说成「它就停手」既是假话，又许诺了产品明确不给的东西。
  testWidgets('Agent 干活时人先别动同一处，但出路就在眼前', (tester) async {
    final repo = _MemoryRepo();
    await pump(tester, repo);
    report(AgentPresence(
        holder: 'Agent', at: DateTime.now(), action: '挑镜头'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    // 试着改台词：应该被拦下并说清怎么办
    await tester.enterText(find.byType(TextField).first, '人改的');
    // 打字期间不写文档（中文输入法的组合不能被打断），停手 1.2 秒才提交
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    final saved = await repo.findById('t1');
    expect(saved!.script!.lines.first.text, isNot('人改的'),
        reason: '两边同时写会把彼此的活覆盖掉');
    // 横幅上有「我来接手」按钮，拦截提示里也指向它——拦下来要给出路
    expect(find.byKey(const ValueKey('agent-takeover')), findsOneWidget);
    expect(find.textContaining('点上面的「我来接手」'), findsOneWidget,
        reason: '拦下来要说清怎么办，不能只是点了没反应');
    expect(find.textContaining('它那条命令还在跑'), findsOneWidget,
        reason: '不许许诺「它就停手」——软件停不掉 Agent，说了就是假话');
    expect(find.textContaining('去 Agent 那头说'), findsOneWidget,
        reason: '真要它停，出路在 Agent 那头，得把这条说出来');
  });

  /// 「我来接手」的确认框曾经写着「它之后的写入会被拒绝」——那是锁还在的
  /// 年代的事实。锁删掉之后那句话变成了**两重谎**：写入不会被拒绝，
  /// 而且它根本不会停。
  ///
  /// 产品负责人定的：**人不能在软件上停止 Agent。人要停它，去 Agent 那头说。**
  /// 所以这个框一个字都不许许诺「它会停」。
  testWidgets('「我来接手」的确认框只说实话：停的是跟随，不是 Agent',
      (tester) async {
    final repo = _MemoryRepo();
    await pump(tester, repo);
    report(AgentPresence(
        holder: 'Agent', at: DateTime.now(), action: '挑镜头'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('agent-takeover')));
    // 这一页有个 500ms 的轮询定时器，pumpAndSettle 永远等不到静止
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.textContaining('停止跟随'), findsOneWidget,
        reason: '这才是它真正做的事');
    expect(find.textContaining('它那条命令还在跑'), findsOneWidget);
    expect(find.textContaining('去 Agent 那头说'), findsOneWidget,
        reason: '真正的出路要指出来，不然人会以为按了就没事了');
    // 页面上本来就有一个「自动铺一版」按钮，所以这里是 findsWidgets
    expect(find.textContaining('自动铺一版'), findsWidgets,
        reason: '界面自己在跑的那个是真停得掉的——别和「停 Agent」混成一句');
    expect(find.textContaining('会被拒绝'), findsNothing,
        reason: '锁没了，没有任何东西会拒绝 Agent 的写入');
    expect(find.textContaining('会被打断'), findsNothing,
        reason: '软件打断不了它');
  });

  /// **「你马上就能改」不能只在几百毫秒内为真。**
  ///
  /// `_watchAgent` 每 500ms 从盘上重读在场状态。而点完接手，Agent 那条命令
  /// 还在跑——`script voice` 每句一两条播报、`tag-ref` 每镜一条，间隔以秒计。
  /// 不压住跟随的话，人点完接手、打两个字，同一句提示又弹出来，再点、再弹。
  ///
  /// 旧版靠「接手后重新上锁，Agent 之后的写入被拒」兑现这句承诺；锁拆了，
  /// 那个保障得有替代品——**压住的是跟随，不是 Agent**。
  testWidgets('接手之后 Agent 又播报了一条：这一页仍然让人改', (tester) async {
    final repo = _MemoryRepo();
    await pump(tester, repo);
    report(AgentPresence(
        holder: 'Agent', at: DateTime.now(), action: '挑镜头'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('agent-takeover')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('agent-takeover-confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Agent 根本没停——它接着写在场状态（真机上这是秒级发生的）
    report(AgentPresence(
        holder: 'Agent', at: DateTime.now(), action: '正在给第 2 句挑镜头'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    // 人接着改：必须真的改得动
    await tester.enterText(find.byType(TextField).first, '人接手后改的');
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    final saved = await repo.findById('t1');
    expect(saved!.script!.lines.first.text, '人接手后改的',
        reason: '点完接手就该一直能改到他离开这一页为止——'
            '不然那句「你马上就能改」只在几百毫秒内为真');
    expect(find.textContaining('点上面的「我来接手」'), findsNothing,
        reason: '已经接手了还弹同一句提示，就是在让人反复点同一个按钮');
  });

  testWidgets('展示完这一步才回执——Agent 靠它决定什么时候走下一步',
      (tester) async {
    final repo = _MemoryRepo();
    await pump(tester, repo);
    expect(readAgentAck(dataDir: dir, taskId: 't1'), -1);

    report(AgentPresence(
      holder: 'Agent',
      at: DateTime.now(),
      action: '正在看第 10 句',
      step: 4,
      focus: const AgentFocus(module: 'director', lineIndex: 9),
    ));
    // 轮询看到 → 上屏 → 停够 visualStepDwell → 才回执，
    // 每一环都要推一拍定时器
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(visualStepDwell);
    await tester.pump(const Duration(milliseconds: 600));

    expect(readAgentAck(dataDir: dir, taskId: 't1'), 4,
        reason: '收到就回的话人还没看清界面已经翻篇了');
  });

  testWidgets('心跳停了就当它走了——Agent 崩掉不能把界面永久锁住',
      (tester) async {
    final repo = _MemoryRepo();
    await pump(tester, repo);
    report(AgentPresence(
        holder: 'Agent',
        at: DateTime.now().subtract(const Duration(seconds: 90)),
        action: '挑镜头'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    expect(find.textContaining('正在操作这个任务'), findsNothing);
  });
}
