import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/busy_guard.dart';
import 'package:ishkafel/core/analysis/analysis_pipeline.dart';
import 'package:ishkafel/core/analysis/analysis_progress.dart';
import 'package:ishkafel/core/storage/task_log.dart';
import 'package:ishkafel/cli/commands/analyze_command.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/storage/agent_presence.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

/// **别把同一条分析管线跑两遍。**
///
/// 整条分析是 ASR + LLM 切分 + 逐镜打标，几分钟、真金白银；而「调用方的
/// 命令超时了、以为失败又起一个」在真机上是常态。此前挡住它的是任务锁
/// （第二个进程撞锁退出），2026-09-18 把锁删掉之后得有别的东西接住。
///
/// 配音、打标那种循环能把幂等落到每一项上；分析是一整条管线，没有「项」
/// 可跳。所以这里给的是**劝告，不是拒绝**：
///
/// - 退出码 0，不是失败
/// - 报的是事实（「另一个进程正在分析」），不是规则
/// - `--force` 这条明路写在输出里，决定权仍在调用方手上
void main() {
  late Directory dir;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('analyze_rerun_');
    // 凭据得齐全，否则命令在走到这道劝告之前就先因为缺凭据退出了
    final creds = Directory('${dir.path}/credentials')
      ..createSync(recursive: true);
    for (final name in const [
      'ark_api_key',
      'speech_app_id',
      'speech_access_token'
    ]) {
      File('${creds.path}/$name').writeAsStringSync('测试用的假凭据');
    }
    await FileTaskRepository(dir).save(RenewTask(
      id: 't1',
      name: '原片',
      // 故意指向一个不存在的文件：真跑起来会在抽音频那一步当场失败，
      // 不打网络、也不会慢——这条测试关心的是「跑没跑」，不是跑成没跑成
      sourcePath: '${dir.path}/没有这个文件.mp4',
      status: RenewTaskStatus.ready,
      createdAt: DateTime.utc(2026, 9, 18),
      updatedAt: DateTime.utc(2026, 9, 18),
    ));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  void reportAnalyzing({DateTime? at, String action = '正在分析原片：抽音频'}) {
    writeAgentPresence(
      dataDir: dir,
      taskId: 't1',
      presence: AgentPresence(
          holder: 'agent:另一个会话', at: at ?? DateTime.now(), action: action),
    );
  }

  test('已经有人在分析：什么都不做，但退出码 0，而且在 JSON 里明说', () async {
    reportAnalyzing();
    final out = StringBuffer();
    final code = await runAnalyzeCommand(
        rest: ['t1'], dataDir: dir, out: out, err: StringBuffer());

    expect(code, 0, reason: '这是劝告，不是拒绝——软件不对 Agent 说「不行」');
    final json = jsonDecode(out.toString()) as Map<String, dynamic>;
    expect(json['ok'], isTrue);
    expect(json['skipped'], isTrue,
        reason: 'Agent 是按 JSON 判断的：只在 stderr 说一句它读不到，'
            '照样会以为分析做完了');
    expect(json['reason'], contains('另一个进程正在分析'));
    expect(json['reason'], contains('抽音频'), reason: '它正在做什么要一起报');
    expect(json['hint'], contains('--force'), reason: '出路必须给出来');

    // 真的什么都没跑：任务一个字没动
    final after = await FileTaskRepository(dir).findById('t1');
    expect(after!.updatedAt, DateTime.utc(2026, 9, 18));
    expect(after.units, isNull);
  });

  test('给了 --force：照常跑（跑不跑得成是另一回事，反正不再跳过）', () async {
    reportAnalyzing();
    final out = StringBuffer();
    final code = await runAnalyzeCommand(
        rest: ['t1'],
        dataDir: dir,
        force: true,
        out: out,
        err: StringBuffer());

    expect(code, isNot(0), reason: '原片文件不存在，分析当然失败——'
        '但那是「干了没成」，不是「被人占着」');
    expect(out.toString(), isNot(contains('"skipped":true')));
  });

  test('在场状态过期了（对方多半崩了）：照常跑，不能被永久挡住', () async {
    // 心跳停了就当它不在——用的是 readAgentPresence 现成的那套失效判据
    // （defaultStaleAfter），这里不另发明一个时限
    reportAnalyzing(
        at: DateTime.now().subtract(defaultStaleAfter * 2));
    final out = StringBuffer();
    final code = await runAnalyzeCommand(
        rest: ['t1'], dataDir: dir, out: out, err: StringBuffer());

    expect(code, isNot(0), reason: '过期的在场状态不该把这条任务永久封死');
    expect(out.toString(), isNot(contains('"skipped":true')));
  });

  /// **判据词得跟真命令的播报对得上**（配音、打标、界面分析三条已经这么钉住
  /// 了，就差这条）。手写在场状态的那几条测试证明不了这件事：
  /// 把开工那句改成「开始处理原片」，判据当场失效，而它们照样全绿。
  test('analyze 开工那一刻，在场状态里带着「分析」这个判据词', () async {
    // 命令跑完会 `stage.end()` 撤干净，所以在**管线跑起来的那一刻**抢一眼
    // ——用注入的假管线，不靠计时器碰运气
    String? seen;
    await runAnalyzeCommand(
      rest: ['t1'],
      dataDir: dir,
      pipeline: _PeekingPipeline(
          () => seen = readAgentPresence(dataDir: dir, taskId: 't1')?.action),
      out: StringBuffer(),
      err: StringBuffer(),
    );

    expect(seen, isNotNull, reason: '开工就该报，另一个进程要靠它才知道有人在做');
    expect(seen, contains(analyzeBusyKeyword),
        reason: '判据认的就是这几个字。文案改了而常量没跟着改，'
            '「别把同一条管线跑两遍」会静默失效');
  });

  test('别人在这条任务上干的是别的活（挑镜头）：不拦', () async {
    reportAnalyzing(action: '正在给第 3 段挑镜头');
    final out = StringBuffer();
    final code = await runAnalyzeCommand(
        rest: ['t1'], dataDir: dir, out: out, err: StringBuffer());

    expect(code, isNot(0),
        reason: '挑镜头跟重跑分析管线没关系，拦它是白拦');
    expect(out.toString(), isNot(contains('"skipped":true')));
  });
}


/// 假分析管线：只在被调用的那一刻偷看一眼在场状态，然后原样返回。
///
/// 不碰真音视频、不打网络——这条测试要证的只有一件事：
/// **命令报出去的那句话，和劝告认的那个判据词，是同一个东西。**
class _PeekingPipeline implements AnalysisPipeline {
  final void Function() peek;
  _PeekingPipeline(this.peek);

  @override
  Future<RenewTask> analyze(RenewTask task,
      {AnalysisProgressSink? onProgress,
      void Function(RenewTask ready)? onUnitsReady,
      ActorKind by = ActorKind.agent,
      String actor = 'Agent'}) async {
    peek();
    return task;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
