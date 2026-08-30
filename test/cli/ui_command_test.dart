import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/cli_output.dart';
import 'package:ishkafel/cli/commands/ui_command.dart';
import 'package:ishkafel/core/storage/agent_presence.dart';
import 'package:ishkafel/core/storage/agent_request.dart';

/// `ishkafel ui new-task` —— **当着人的面**新建任务。
///
/// 和 `script new` 的区别不是结果，是过程：那条在后台把任务建好、界面
/// 一动不动（真机上就是这样，用户说「建了任务 5，界面什么都没发生」）；
/// 这一条会把软件拉起来、真的弹出向导、真的填、真的点创建。
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('ui_cmd_'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<int> run(List<String> rest,
      {String? mode,
      String? file,
      String? tagGroups,
      String? name,
      StringSink? out,
      StringSink? err,
      Duration? wait}) =>
      runUiCommand(
        rest: rest,
        dataDir: dir,
        mode: mode,
        file: file,
        tagGroups: tagGroups,
        name: name,
        env: const {},
        appExists: (_) => true,
        waitForUi: wait ?? const Duration(milliseconds: 300),
        // 测试里不真的等冷启动那几秒
        coldStartWait: Duration.zero,
        out: out,
        err: err,
        run: (bin, args) async =>
            // pgrep 返回非零 = app 没在跑；open 照常成功
            bin == 'pgrep'
                ? ProcessResult(0, 1, '', '')
                : ProcessResult(0, 0, '', ''),
      );

  test('参数不对时**不弹向导**——让人看着窗口弹出来又关掉，比不弹更糟', () async {
    final err = StringBuffer();
    // renew 没给原片
    expect(await run(['new-task'], mode: 'renew', tagGroups: '1', err: err),
        exitBadUsage);
    expect(err.toString(), contains('原片'));
    expect(consumeAgentRequest(dataDir: dir, taskId: globalPresenceSlot),
        isNull, reason: '连单都不该下');
  });

  test('一个标签组都没给：拒绝并说清后果', () async {
    final err = StringBuffer();
    expect(await run(['new-task'], mode: 'script', err: err), exitBadUsage);
    expect(err.toString(), contains('标签组'));
  });

  test('mode 认不出时列出可选的三条线', () async {
    final err = StringBuffer();
    expect(await run(['new-task'], mode: '随便写', tagGroups: '1', err: err),
        exitBadUsage);
    expect(err.toString(), contains('script'));
    expect(err.toString(), contains('replace'),
          reason: '报错里要给现在的词——人照着报错去敲，写出来的就是它');
    expect(err.toString(), contains('blank'));
  });

  test('参数合格：下单给界面，并把要建什么说清楚', () async {
    final err = StringBuffer();
    final f = Future(() => run(['new-task'],
        mode: 'script', tagGroups: '1261,1262', err: err));
    // 扮演界面：取单
    AgentRequest? got;
    for (var i = 0; i < 40 && got == null; i++) {
      got = consumeAgentRequest(dataDir: dir, taskId: globalPresenceSlot);
      if (got == null) await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(got, isNotNull);
    expect(got!.kind, 'wizard.open');
    expect(got.payload['mode'], 'script');
    expect(got.payload['tagGroupIds'], [1261, 1262]);
    await f;
  });

  test('界面没回应：报失败，不能报成功——人会以为任务建好了', () async {
    final err = StringBuffer();
    expect(await run(['new-task'], mode: 'script', tagGroups: '1', err: err),
        isNot(0));
    expect(err.toString(), contains('没有回应'));
  });

  test('界面说没建成，原因原样带回来', () async {
    final err = StringBuffer();
    final f = Future(() => run(['new-task'],
        mode: 'script', tagGroups: '1', err: err,
        wait: const Duration(seconds: 2)));
    for (var i = 0; i < 60; i++) {
      final req = consumeAgentRequest(dataDir: dir, taskId: globalPresenceSlot);
      if (req != null) {
        writeAgentRequestResult(
            dataDir: dir, taskId: globalPresenceSlot, id: req.id,
            ok: false, message: '人把向导关掉了');
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await f, isNot(0));
    expect(err.toString(), contains('人把向导关掉了'));
  });

  /// 洞 17（真机撞到、当轮最严重的一条）：macOS 弹了「想访问文稿文件夹」
  /// 的授权框，没人点允许，任务**压根没建成**——而 CLI 去任务库里翻
  /// 「创建时间最新的那条」，把**上一次**建的任务报了出来，还带着
  /// `ok:true`「任务已经建好了」。
  ///
  /// 后果是 Agent 拿着一个错任务的 id 一路往下走：给它挑素材、提交方案、
  /// 导出——每一步都「成功」，人最后拿到的是一条完全无关的片子。
  test('界面说建好了却没报是哪一条：宁可失败，也绝不去列表里猜', () async {
    // 盘上放一条**旧**任务：以前 CLI 就是把这条当成「刚建的」报出去的
    Directory('${dir.path}/tasks').createSync(recursive: true);
    File('${dir.path}/tasks/old1.json').writeAsStringSync(jsonEncode({
      'id': 'old1',
      'name': '上一次建的',
      'seq': 8,
      'status': 'ready',
      'createdAt': DateTime.now().toIso8601String(),
      'updatedAt': DateTime.now().toIso8601String(),
      'units': <dynamic>[],
    }));
    final out = StringBuffer();
    final err = StringBuffer();
    final f = Future(() => run(['new-task'],
        mode: 'script', tagGroups: '1', out: out, err: err,
        wait: const Duration(seconds: 2)));
    for (var i = 0; i < 60; i++) {
      final req = consumeAgentRequest(dataDir: dir, taskId: globalPresenceSlot);
      if (req != null) {
        // 界面报了成功，但 payload 里没有 taskId
        writeAgentRequestResult(
            dataDir: dir, taskId: globalPresenceSlot, id: req.id,
            ok: true, message: '任务已经建好了');
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(await f, isNot(0), reason: '报 ok:true 的话，Agent 会拿着错 id 一路往下走');
    expect(out.toString(), isNot(contains('old1')),
        reason: '**绝不能把上一次的任务当成刚建的报出去**——'
            '这正是洞 17 的原样');
    expect(err.toString(), contains('别照着猜'));
  });

  test('建成之后要报出是哪一条任务——不然调用方只能去列表里猜', () async {
    // 先放一条任务在盘上，模拟界面刚建好的那一条
    Directory('${dir.path}/tasks').createSync(recursive: true);
    File('${dir.path}/tasks/new1.json').writeAsStringSync(jsonEncode({
      'id': 'new1',
      'name': '刚建的',
      'seq': 9,
      'status': 'ready',
      'createdAt': DateTime.now().toIso8601String(),
      'updatedAt': DateTime.now().toIso8601String(),
      'units': <dynamic>[],
    }));
    final out = StringBuffer();
    final f = Future(() => run(['new-task'],
        mode: 'script', tagGroups: '1', out: out,
        wait: const Duration(seconds: 2)));
    for (var i = 0; i < 60; i++) {
      final req = consumeAgentRequest(dataDir: dir, taskId: globalPresenceSlot);
      if (req != null) {
        // 界面把**真正建出来的那条**回传（以前 CLI 只能去任务库里
        // 翻「最新的那条」猜，授权框挡住创建时就猜成了上一次的任务）
        writeAgentRequestResult(
            dataDir: dir, taskId: globalPresenceSlot, id: req.id,
            ok: true, message: '任务已经建好了',
            payload: const {'taskId': 'new1', 'kind': 'script'});
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await f, 0);
    final json = jsonDecode(out.toString()) as Map<String, dynamic>;
    expect(json['id'], 'new1');
    expect(json['seq'], 9);
    expect(json['next'], contains('new1'),
        reason: '直接给出下一条命令，省得调用方自己拼');
  });

  test('--name 要真的传到界面那头——上一轮我说做了却没接上线', () async {
    final f = Future(() => run(['new-task'],
        mode: 'script', tagGroups: '1', name: '验证-复刻滴露'));
    AgentRequest? got;
    for (var i = 0; i < 40 && got == null; i++) {
      got = consumeAgentRequest(dataDir: dir, taskId: globalPresenceSlot);
      if (got == null) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
    expect(got!.payload['name'], '验证-复刻滴露',
        reason: '只跑 analyze 不验行为，参数没接上线也看不出来');
    await f;
  });

  test('认不出的子命令给用法', () async {
    final err = StringBuffer();
    expect(await run(['乱写'], err: err), exitBadUsage);
    expect(err.toString(), contains('new-task'));
  });

  /// 洞 17：macOS 弹了「想访问文稿文件夹」的授权框，没人点允许，
  /// 任务压根没建成——而 CLI 去任务库里翻「创建时间最新的那条」，
  /// 把**上一次**建的任务报了出来，还带着 ok:true「任务已经建好了」。
  ///
  /// 人照着那个 id 往下走，操作的是另一条任务。这一条对可视化杀伤最大：
  /// 人就坐在旁边看着，除非他知道 replace 就是替换裂变，
  /// 否则根本发现不了建错了。
  test('界面没报出建了哪一条时，不许去猜——宁可失败', () async {
    // 任务库里躺着一条旧任务：以前会被当成「刚建的」报出去
    File('${dir.path}/tasks/old.json')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({
        'id': 'old',
        'name': '上一次建的',
        'seq': 1,
        'status': 'ready',
        'createdAt': DateTime.now().toIso8601String(),
        'updatedAt': DateTime.now().toIso8601String(),
      }));

    final err = StringBuffer();
    final f = Future(() => run(['new-task'],
        mode: 'script', tagGroups: '1', err: err,
        wait: const Duration(seconds: 2)));
    for (var i = 0; i < 60; i++) {
      final req = consumeAgentRequest(dataDir: dir, taskId: globalPresenceSlot);
      if (req != null) {
        // 界面说建好了，但没报是哪一条（老版本的回执就长这样）
        writeAgentRequestResult(
            dataDir: dir, taskId: globalPresenceSlot, id: req.id,
            ok: true, message: '任务已经建好了');
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(await f, isNot(0), reason: '猜一个 id 报出去比失败更糟');
    expect(err.toString(), contains('没报出'));
  });

}
