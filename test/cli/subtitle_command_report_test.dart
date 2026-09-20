import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/cli_output.dart';
import 'package:ishkafel/cli/commands/subtitle_command.dart';
import 'package:ishkafel/core/ai/frame_check.dart';
import 'package:ishkafel/core/ai/frame_check_wiring.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

import '../support/seed_task.dart';

/// 造一条「有一镜挑了候选素材、那条候选画面上自带烧录字」的任务，
/// 并把烧字自查结果直接 put 进 [dataDir] 对应的缓存——不用真跑 AI，
/// 只是给 `subtitleShotReport`/`subtitleReport` 一条能查到的数据。
///
/// 用来验证命令层真的把 dataDir 递下去了：漏传的话 burned 那个键会
/// 整个不出现（见 subtitle_view.dart 的「没查」三态），而且没有任何
/// 报错——静默从「有风险」变成「没查」，正是这条测试要拦住的
Future<String> _seedTaskWithBurnedCandidate(Directory dataDir) async {
  final task = RenewTask(
    id: 't_burn',
    name: '测试烧字',
    status: RenewTaskStatus.ready,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
    units: const [
      SemanticUnit(
        uid: 'u0',
        index: 0,
        startMs: 0,
        endMs: 2000,
        transcript: '甲乙',
        shots: [Shot(startMs: 0, endMs: 1000), Shot(startMs: 1000, endMs: 2000)],
      ),
    ],
    replacementsByUid: {
      'u0': UnitReplacement.perShot({0: const [7]}),
    },
  );
  await FileTaskRepository(dataDir).save(task);
  frameCheckCacheIn(dataDir)
      .put(7, const FrameCheck(burnedText: ['冰冰凉凉的好舒服呀']));
  return task.id;
}

/// 造一条**已经分析过**的任务（有单元、有镜头）。
///
/// `seedTask` 那份最小任务的 `units` 是 null——那是「还没分析」，报告会
/// 如实退回一句 `notAnalyzed`，拿它去验报告内容等于在验一条降级路径。
/// 真机上这个洞害过一轮：报告看起来正常，其实一个镜头都没算
Future<String> _seedAnalyzedTask(Directory dataDir) async {
  final task = RenewTask(
    id: 't_analyzed',
    name: '测试已分析',
    status: RenewTaskStatus.ready,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
    units: const [
      SemanticUnit(
        uid: 'u0',
        index: 0,
        startMs: 0,
        endMs: 2000,
        transcript: '甲乙',
        shots: [Shot(startMs: 0, endMs: 1000), Shot(startMs: 1000, endMs: 2000)],
      ),
    ],
  );
  await FileTaskRepository(dataDir).save(task);
  return task.id;
}

void main() {
  late Directory dataDir;
  setUp(() => dataDir = Directory.systemTemp.createTempSync('ishkafel_subcmd'));
  tearDown(() => dataDir.deleteSync(recursive: true));

  test('check 只出问题清单，别的什么都不给', () async {
    final id = await _seedAnalyzedTask(dataDir);
    final out = StringBuffer();
    final code =
        await runSubtitleCommand(rest: ['check', id], dataDir: dataDir, out: out);
    expect(code, 0);
    final json = jsonDecode(out.toString()) as Map<String, dynamic>;
    expect(json.keys, contains('problems'));
    expect(json.containsKey('shots'), isFalse,
        reason: 'check 是入口，不是报告——给细节就没人看了');
  });

  test('show 出全片报告', () async {
    final id = await _seedAnalyzedTask(dataDir);
    final out = StringBuffer();
    await runSubtitleCommand(rest: ['show', id], dataDir: dataDir, out: out);
    expect((jsonDecode(out.toString()) as Map).keys, contains('shots'));
  });

  /// **这条路原来唯一的覆盖，正是 I6 改夹具时换走的那两条。**
  ///
  /// 「check 只出问题清单」和「show 出全片报告」以前用的是 `seedTask`
  /// （`units` 为 null），无意中把「还没分析」这条路盖住了；I6 把它们换成
  /// 已分析的夹具之后，覆盖跟着修复一起没了，于是 `_checkReport` 漏判
  /// `notAnalyzed`、`report['shots']` 是 null、`as List` 当场抛，
  /// 全量 4769 绿照不出来。
  ///
  /// **面向用户的命令不该抛 Dart 类型错。** 这两条专门钉住「还没分析」
  /// 这条路
  test('还没分析的任务跑 check：给实话，不许抛', () async {
    final id = (await seedTask(dataDir)).id; // units 为 null
    final out = StringBuffer();
    final code =
        await runSubtitleCommand(rest: ['check', id], dataDir: dataDir, out: out);
    expect(code, 0);
    final json = jsonDecode(out.toString()) as Map<String, dynamic>;
    expect(json.containsKey('notAnalyzed'), isTrue,
        reason: '这条路原来唯一的覆盖，被 I6 换夹具时一起换走了');
  });

  test('还没分析的任务跑 show：同样给实话，不许抛', () async {
    final id = (await seedTask(dataDir)).id;
    final out = StringBuffer();
    final code =
        await runSubtitleCommand(rest: ['show', id], dataDir: dataDir, out: out);
    expect(code, 0);
    final json = jsonDecode(out.toString()) as Map<String, dynamic>;
    expect(json.containsKey('notAnalyzed'), isTrue);
    expect(json.containsKey('shots'), isFalse,
        reason: '空的 shots 跟「分析完了、确实没有镜头」分不开');
  });

  test('不给子命令时还是老样子——样式现状', () async {
    final id = (await seedTask(dataDir)).id;
    final out = StringBuffer();
    final code =
        await runSubtitleCommand(rest: [id], dataDir: dataDir, out: out);
    expect(code, 0);
    expect(out.toString(), contains('preset'),
        reason: '老用法不许一声不响地失效');
  });

  /// **拧了旋钮、软件当没看见，还看起来像成功了**，是这三条的共同形状。
  /// 实测下来三种全是 exit 0、照常吐全片报告，一句话都不说
  test('show 只给了 --unit：当场说清要两个一起给，不许默默吐全片', () async {
    final id = (await seedTask(dataDir)).id;
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runSubtitleCommand(
        rest: ['show', id], dataDir: dataDir, unitIndex: 1,
        out: out, err: err);
    expect(code, exitBadUsage);
    expect(out.toString(), isEmpty, reason: '别一边报错一边照样吐报告');
    expect(err.toString(), contains('--shot'));
  });

  test('show 只给了 --shot：同理', () async {
    final id = (await seedTask(dataDir)).id;
    final err = StringBuffer();
    final code = await runSubtitleCommand(
        rest: ['show', id], dataDir: dataDir, shotIndex: 2, err: err);
    expect(code, exitBadUsage);
    expect(err.toString(), contains('--unit'));
  });

  test('check 是全片自查，给了 --unit/--shot 要说清该敲哪条命令', () async {
    final id = (await seedTask(dataDir)).id;
    final err = StringBuffer();
    final code = await runSubtitleCommand(
        rest: ['check', id], dataDir: dataDir,
        unitIndex: 1, shotIndex: 2, err: err);
    expect(code, exitBadUsage);
    expect(err.toString(), contains('subtitle show'),
        reason: '不能只说「不行」，要指一条能照做的路');
  });

  /// 失败理由只能是「参数不对」这一类——仓库有架构测试拦
  /// （`no_permission_refusals_test`），这里再当场守一道
  test('这几条的说法里不许出现「没有权限 / 被占用」那一套', () async {
    final id = (await seedTask(dataDir)).id;
    final err = StringBuffer();
    await runSubtitleCommand(
        rest: ['show', id], dataDir: dataDir, unitIndex: 1, err: err);
    for (final word in ['没有权限', '不许', '被占用']) {
      expect(err.toString().contains(word), isFalse, reason: '是参数不对，不是禁止');
    }
  });

  test('--unit 给了但不是整数：报错，不许当没给', () {
    final bad = intArg('unit', 'abc');
    expect(bad.value, isNull);
    expect(bad.error, isNotNull,
        reason: 'int.tryParse 失败变 null，跟「没给 --unit」长得一模一样——'
            '命令会照常吐全片报告、退出码 0');
    expect(intArg('unit', null).error, isNull, reason: '真没给就是真没给');
    expect(intArg('unit', ' 3 ').value, 3);
  });

  test('bin 里 subtitle 的 --unit/--shot 要真走 intArg', () {
    // 上面那条只测了 intArg 本身。bin 那头还写着 int.tryParse 的话，
    // 它照样全绿，而真敲命令的人还是碰到静默忽略。
    //
    // **截块不能靠 `'),'`**：那个标记在 `_intArgOrFail(parsed, 'unit'),`
    // 这一行就命中了，`shotIndex` 那行压根不在检查范围里——名字写着
    // --unit/--shot，实际只守住 unit（复评把 shotIndex 单独退回
    // int.tryParse，这条测试照样全绿）。改成截到下一条命令的分发行，
    // 并且**点两处**：两个参数各一处，只守住一个等于没守
    final src = File('bin/ishkafel.dart').readAsStringSync();
    final start = src.indexOf("'subtitle' => await runSubtitleCommand(");
    expect(start, greaterThan(0), reason: '找不到 subtitle 的分发点了，回来看看');
    // 顶层每条命令的分发都是「换行 + 4 个空格 + 单引号命令名」
    final end = src.indexOf("\n    '", start + 1);
    expect(end, greaterThan(start), reason: '截不到这一块的结尾，这条测试是空转的');
    final block = src.substring(start, end);
    expect(block.contains('int.tryParse'), isFalse,
        reason: 'int.tryParse 把「给了但不是整数」和「没给」混成一件事');
    expect(RegExp('_intArgOrFail').allMatches(block).length, 2,
        reason: '--unit 和 --shot 各要一处；只有一处就是只守住了其中一个');
  });

  test('任务不存在就直说', () async {
    final err = StringBuffer();
    final code = await runSubtitleCommand(
        rest: ['show', '没这条'], dataDir: dataDir, err: err);
    expect(code, exitNotFound);
  });

  test('命令层要把 dataDir 递下去——不然 Agent 永远看不到烧字风险', () async {
    final id = await _seedTaskWithBurnedCandidate(dataDir);
    final out = StringBuffer();
    await runSubtitleCommand(
        rest: ['show', id],
        dataDir: dataDir,
        unitIndex: 0,
        shotIndex: 0,
        out: out);
    final json = jsonDecode(out.toString()) as Map<String, dynamic>;
    expect(json.containsKey('burned'), isTrue,
        reason: '漏传 dataDir 的话这里会静默变成「根本没查」，而且没人会发现');
    expect(json['burned'], contains('冰冰凉凉的好舒服呀'));
  });

  test('show 全片那条路也要把 dataDir 递下去', () async {
    // check/show --unit --shot 两条走的都是单镜路径（subtitleShotReport），
    // show 不带 --unit/--shot 时走的是另一处调用（subtitleReport）——
    // 四处传参各自独立，这条专守全片报告那一处
    final id = await _seedTaskWithBurnedCandidate(dataDir);
    final out = StringBuffer();
    await runSubtitleCommand(rest: ['show', id], dataDir: dataDir, out: out);
    final json = jsonDecode(out.toString()) as Map<String, dynamic>;
    final shots = (json['shots'] as List).cast<Map<String, dynamic>>();
    final row = shots.firstWhere((s) => s['at'] == 'U1S1');
    final kinds = (row['problems'] as List?) ?? const [];
    expect(kinds, contains('burnedTextPresent'),
        reason: '四处调用各传各的，漏一处就静默变成「根本没查」，'
            '而这一处是 Agent 扫全片时唯一会走的路');
  });

  test('check 同理：漏传 dataDir 会让烧字风险从问题清单里消失', () async {
    final id = await _seedTaskWithBurnedCandidate(dataDir);
    final out = StringBuffer();
    await runSubtitleCommand(rest: ['check', id], dataDir: dataDir, out: out);
    final json = jsonDecode(out.toString()) as Map<String, dynamic>;
    final problems = (json['problems'] as List).cast<Map<String, dynamic>>();
    final p = problems.firstWhere((p) => p['kind'] == 'burnedTextPresent');
    // 只断言 kind 逮不住「check 里为了拿 note 补的那次 subtitleShotReport
    // 漏传 dataDir」——那一步漏传的话代码会走 fallback，拿全片报告（已经
    // 传了 dataDir）的 kind 拼一条没有 note 的记录，kind 照样在、测试照样
    // 绿。note 只有单镜报告算得出来，断言它的内容才逮得住这一处漏传
    expect(p['note'], isNotNull, reason: 'note 只有单镜报告给得出来');
    expect(p['note'], contains('冰冰凉凉的好舒服呀'));
  });
}
