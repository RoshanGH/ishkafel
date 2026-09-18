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

  /// **假 Agent 真的往盘上写一次任务文件**，让 `taskFingerprint` 变。
  ///
  /// 只写在场状态的假 Agent 骗不出那个 bug——指纹不变，指纹闸就不会关。
  /// 真机上 `script voice` 每配一句就是一次 `TaskMutation`，盘上真的在变。
  var diskWrites = 0;
  void agentWritesToDisk(String why) {
    final f = File('${dir.path}/tasks/t1.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"id":"t1","why":"$why","n":${diskWrites++}}');
    // 指纹是「大小 + 修改时间」，同一毫秒内连写两次可能看起来没变
    f.setLastModifiedSync(
        DateTime.now().add(Duration(seconds: 10 * diskWrites)));
  }

  /// Agent 真的改了第一句台词并落盘：**仓库和指纹两边都动**。
  ///
  /// 只动指纹（`agentWritesToDisk`）证不了「屏幕上换成了它的最终版」；
  /// 只动仓库证不了指纹闸的行为。这一条两样都要。
  Future<void> agentSaves(_MemoryRepo repo, String text) async {
    final was = (await repo.findById('t1'))!;
    await repo.save(was.copyWith(script: was.script!.updateText(0, text)));
    agentWritesToDisk(text);
  }

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

  /// **这一条守的是「接手之后人的编辑被静默丢掉」。**
  ///
  /// 上一轮为了兑现「我来接手」，把整个跟随都停掉了——结果 `_docPrint`
  /// 从那一刻起冻死，而 Agent 那条命令**还在真的写盘**（`script voice`
  /// 每句一次 `TaskMutation`）。指纹一变，`canOverwrite` 从此永远为 false，
  /// 人之后的每一次保存都被**静默丢掉**，顶栏还一直挂着「保存中…」。
  /// **字在屏幕上、提示说在存，离开页面全没了。**
  ///
  /// 上一条时序测试抓不到它：那儿的假 Agent 只写在场状态、**从不写任务
  /// 文件**，指纹不变，保存照常成功。所以这里的假 Agent **要真的写盘**。
  testWidgets('接手之后 Agent 还在写盘：人的编辑照样存得进去，顶栏不卡在「保存中」',
      (tester) async {
    final repo = _MemoryRepo();
    await pump(tester, repo);
    report(AgentPresence(
        holder: 'Agent', at: DateTime.now(), action: '正在给第 5 句配音'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('agent-takeover')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('agent-takeover-confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // **Agent 真的写了一次盘**（它那条命令根本没停），指纹跟着变
    agentWritesToDisk('第一次');
    report(AgentPresence(
        holder: 'Agent', at: DateTime.now(), action: '正在给第 6 句配音'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    await tester.enterText(find.byType(TextField).first, '人接手后改的');
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    final saved = await repo.findById('t1');
    expect(saved!.script!.lines.first.text, '人接手后改的',
        reason: 'Agent 还在写盘不该让人的编辑被静默丢掉——'
            '那正是这一整批要消灭的那个形状');
    expect(find.text('保存中…'), findsNothing,
        reason: '顶栏卡在「保存中…」比不说话更糟：它在说谎');
  });

  /// 指纹闸真的挡下来的时候（人手上有没落盘的改动、Agent 同时又写了盘），
  /// **不许只 return**：那会让顶栏一直挂着「保存中…」，人以为存上了。
  /// 要说出来，而且要给一条一按就走得通的出路。
  testWidgets('保存被拦下来：说出来，并给「以我的为准」这条出路', (tester) async {
    final repo = _MemoryRepo();
    await pump(tester, repo);

    // 先让这一页有个指纹基线
    agentWritesToDisk('基线');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    // 人开始改（此刻 _saving = true，跟随不会拿盘上的盖掉他）
    await tester.enterText(find.byType(TextField).first, '人改的');
    await tester.pump(const Duration(milliseconds: 200));
    // 就在这段窗口里 Agent 又写了一次盘
    agentWritesToDisk('Agent 又写了一次');
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(find.textContaining('没敢覆盖它'), findsWidgets,
        reason: '拦下来要说实话，不能挂着「保存中…」');
    expect(find.text('保存中…'), findsNothing);

    // 出路：点开 → 确认（破坏性操作要先问一遍）→ 真的存得进去
    await tester.tap(find.byKey(const ValueKey('director-force-save')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester
        .tap(find.byKey(const ValueKey('director-force-save-confirm')));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    final saved = await repo.findById('t1');
    expect(saved!.script!.lines.first.text, '人改的',
        reason: '「以我的为准」要真的存得进去，不然那只是一个安慰按钮');
  });

  /// **时序 1（主干路）：人一个字没改 + Agent 收工。**
  ///
  /// 这条被我修坏过一次：早退的判据用了 `_overwriteBlocked`（「盘上变过」），
  /// 而 Agent 收工那一刻它必然为真——于是屏幕永远停在倒数第二版、从此不再
  /// 跟随、还弹一句「你手上还有没保存的改动」的假话。
  /// **判「换不换」只能看 `_dirty`（本地有没有未落盘的改动）。**
  testWidgets('时序1 人没改过 + Agent 收工：屏幕上是它的最终版，一句提示都不弹',
      (tester) async {
    final repo = _MemoryRepo();
    await pump(tester, repo);
    report(AgentPresence(
        holder: 'Agent', at: DateTime.now(), action: '正在给第 1 句配音'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    // Agent 连写两版，最后一笔紧接着收工（静默模式下 stage.end() 无延迟）
    await agentSaves(repo, 'Agent 第一版');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    await agentSaves(repo, 'Agent 最后一笔');
    clearAgentPresence(dataDir: dir, taskId: 't1');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Agent 最后一笔'), findsWidgets,
        reason: '人一个字没改，屏幕上就该是它的最终版');
    expect(find.textContaining('没保存的改动'), findsNothing,
        reason: '他没有未保存的改动——说有就是假话');
    expect(find.textContaining('没敢覆盖'), findsNothing);

    // 而且从此还跟得动：Agent 回来再写一版，屏幕要跟上
    report(AgentPresence(
        holder: 'Agent', at: DateTime.now(), action: '又回来了'));
    await tester.pump(const Duration(milliseconds: 600));
    await agentSaves(repo, 'Agent 又一版');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(find.text('Agent 又一版'), findsWidgets,
        reason: '指纹基线没对齐的话，这一页从此永久不再跟随');
  });

  /// **时序 2：人改了字没保存 + Agent 收工。**
  ///
  /// 和时序 1 只差一件事——本地有没有未落盘的改动。**判据换对了，这两条
  /// 才会分别走向正确的两个方向**：这一条保住人的，时序 1 载入 Agent 的。
  testWidgets('时序2 人改了字没保存 + Agent 收工：保住人的，提示说的是实话',
      (tester) async {
    final repo = _MemoryRepo();
    await pump(tester, repo);
    agentWritesToDisk('基线');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    // 人先改字（这会儿 Agent 还没来，改得动）
    await tester.enterText(find.byType(TextField).first, '人没存的那一笔');
    await tester.pump(const Duration(milliseconds: 200));
    // 同一段窗口里 Agent 写了盘 → 人的自动保存被指纹闸拦下
    await agentSaves(repo, 'Agent 最后一笔');
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.textContaining('没敢覆盖它'), findsWidgets);

    // Agent 露个面然后收工 → 走 leaving 那条路
    report(AgentPresence(
        holder: 'Agent', at: DateTime.now(), action: '正在收尾'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    clearAgentPresence(dataDir: dir, taskId: 't1');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('人没存的那一笔'), findsWidgets,
        reason: '整份重读会把他没落盘的那笔静默换掉，撤销栈还一起清了');
    expect(find.textContaining('Agent 收工了'), findsOneWidget,
        reason: '这条路上它确实收工了——这句是实话，该说');
    expect(find.textContaining('还有没保存的改动'), findsOneWidget);
  });

  /// **时序 4：闸已经关上之后，还出得去吗。**
  ///
  /// `_overwriteBlocked` 一旦置真，只有保存成功才复位——而它被闸挡着永远
  /// 不会成功。不给自愈的话这一页就冻住了：再也不跟随、每次保存都被拦。
  testWidgets('时序4 闸关上之后：人的改动一存进去，这一页就恢复正常',
      (tester) async {
    final repo = _MemoryRepo();
    await pump(tester, repo);
    agentWritesToDisk('基线');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    // 先把闸关上（人改了字 + 盘上同时被改）
    await tester.enterText(find.byType(TextField).first, '人改的');
    await tester.pump(const Duration(milliseconds: 200));
    agentWritesToDisk('Agent 又写了一次');
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.textContaining('没敢覆盖它'), findsWidgets);

    // 出路：以我的为准 → 存进去 → 闸复位
    await tester.tap(find.byKey(const ValueKey('director-force-save')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester
        .tap(find.byKey(const ValueKey('director-force-save-confirm')));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(find.textContaining('没敢覆盖它'), findsNothing,
        reason: '存进去了闸就该复位，不然这一页永久冻住');
    expect(find.byKey(const ValueKey('director-force-save')), findsNothing);

    // 恢复正常：再改一次，照常存得进去
    await tester.enterText(find.byType(TextField).first, '再改一次');
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect((await repo.findById('t1'))!.script!.lines.first.text, '再改一次');
  });

  /// **时序 3：人改了字没保存 + 按「我来接手」（Agent 没收工）。**
  ///
  /// `_takeoverFromAgent` 末尾会重读一次盘——那一下不许把人没落盘的改动
  /// 静默换掉（连撤销栈都清）。而且这条路上**Agent 那条命令还在跑**
  /// （确认框上一秒刚亲口说过），提示里不许出现「Agent 收工了」
  /// ——同一段流程里两句话互相打脸。
  testWidgets('时序3 人改了字没保存 + 按我来接手：改动保住，提示说的是实话',
      (tester) async {
    final repo = _MemoryRepo();
    await pump(tester, repo);

    agentWritesToDisk('基线');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    // 人先改了字，而同一段窗口里 Agent 又写了盘 → 保存被指纹闸拦下
    await tester.enterText(find.byType(TextField).first, '人还没存的改动');
    await tester.pump(const Duration(milliseconds: 200));
    agentWritesToDisk('Agent 又写了一次');
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.textContaining('没敢覆盖它'), findsWidgets);

    // 这时 Agent 来了，人按「我来接手」——那条路会走 _reloadAfterAgent
    report(AgentPresence(
        holder: 'Agent', at: DateTime.now(), action: '正在给第 5 句配音'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('agent-takeover')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('agent-takeover-confirm')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('人还没存的改动'), findsWidgets,
        reason: '整份重读会把他没落盘的那笔静默换掉，撤销栈还一起清了');
    expect(find.textContaining('没敢拿盘上的盖掉它'), findsOneWidget,
        reason: '不换也要说出来，并指向「以我的为准」那条出路');
    expect(find.textContaining('Agent 收工了'), findsNothing,
        reason: '这条路上它还在跑——确认框上一秒刚说过，'
            '这儿再说「收工了」就是同一段流程里两句话互相打脸');
  });

  /// 「以我的为准」会覆盖 Agent 在这段窗口里写进去的那几处——
  /// **破坏性操作要有确认，而且要说清后果**（设计标准里的一条）
  testWidgets('「以我的为准」先问一遍，并说清会盖掉什么', (tester) async {
    final repo = _MemoryRepo();
    await pump(tester, repo);
    agentWritesToDisk('基线');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    await tester.enterText(find.byType(TextField).first, '人改的');
    await tester.pump(const Duration(milliseconds: 200));
    agentWritesToDisk('Agent 又写了一次');
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('director-force-save')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.textContaining('盖掉它这段时间写进去的那几处'), findsOneWidget,
        reason: '一按就覆盖而不说后果，是破坏性操作没有确认');
    // 先不存：什么都不该发生
    await tester.tap(find.text('先不存'));
    await tester.pump(const Duration(seconds: 1));
    expect((await repo.findById('t1'))!.script!.lines.first.text,
        isNot('人改的'));
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
