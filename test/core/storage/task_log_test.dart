import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/storage/task_log.dart';

/// 日志是这次协作模型的地基：锁删掉之后，「谁在什么时候改了什么」只剩它回答。
/// 它记漏一笔，Agent 查到的「什么都没发生」看起来正好像「一切正常」。
void main() {
  late Directory dataDir;

  setUp(() => dataDir = Directory.systemTemp.createTempSync('ishkafel_log'));
  tearDown(() => dataDir.deleteSync(recursive: true));

  TaskLogFile fileOf(String taskId) =>
      TaskLogFile(dataDir: dataDir, taskId: taskId);

  test('seq 从 1 开始，逐笔递增', () {
    final log = fileOf('t1');
    expect(log.latestSeq, 0);
    expect(log.append(by: ActorKind.agent, actor: 'Agent', op: 'shot.pick'), 1);
    expect(log.append(by: ActorKind.human, actor: '人（工作台）', op: 'shot.remove'), 2);
    expect(log.latestSeq, 2);
  });

  test('新进程读到的 seq 接着上一次往下，不从 1 重来', () {
    fileOf('t1').append(by: ActorKind.agent, actor: 'Agent', op: 'shot.pick');
    // 换一个实例 = 换一个进程
    expect(fileOf('t1').append(by: ActorKind.agent, actor: 'Agent', op: 'x'), 2);
  });

  test('判断依据原样存下来，不被压扁成 id', () {
    final log = fileOf('t1');
    log.append(
      by: ActorKind.human,
      actor: '人（工作台）',
      op: 'shot.remove',
      where: {'unitUid': 'u-abc', 'shot': 1},
      before: {
        'materialId': 105475,
        'tags': ['实拍', '产品特写', '手持'],
        'durationMs': 2400,
        'sceneDescription': '手持喷瓶对着灶台喷洒，画面右下有平台水印',
      },
      note: '人在时间线上右键删除',
    );
    final got = log.read().single;
    expect(got.by, ActorKind.human);
    expect(got.where['unitUid'], 'u-abc');
    expect(got.before!['tags'], ['实拍', '产品特写', '手持']);
    expect(got.before!['sceneDescription'], contains('平台水印'));
  });

  test('--since 只给之后的，--by 只给那一方', () {
    final log = fileOf('t1');
    log.append(by: ActorKind.agent, actor: 'Agent', op: 'a');   // 1
    log.append(by: ActorKind.human, actor: '人', op: 'b');       // 2
    log.append(by: ActorKind.agent, actor: 'Agent', op: 'c');   // 3
    expect(log.read(since: 1).map((e) => e.op), ['b', 'c']);
    expect(log.read(by: ActorKind.human).map((e) => e.op), ['b']);
    expect(log.read(since: 1, by: ActorKind.agent).map((e) => e.op), ['c']);
  });

  test('两条任务的日志互不串台', () {
    fileOf('t1').append(by: ActorKind.agent, actor: 'Agent', op: 'a');
    expect(fileOf('t2').latestSeq, 0);
    expect(fileOf('t2').read(), isEmpty);
  });

  test('坏行跳过，其余照读——一条坏记录不许把整份日志废掉', () {
    final log = fileOf('t1');
    log.append(by: ActorKind.agent, actor: 'Agent', op: 'a');
    File('${dataDir.path}/logs/t1.jsonl')
        .writeAsStringSync('{这不是 json\n', mode: FileMode.append);
    log.append(by: ActorKind.agent, actor: 'Agent', op: 'c');
    expect(log.read().map((e) => e.op), ['a', 'c']);
  });

  test('deleteAll 把这条任务的日志清掉——任务删了不留孤儿', () {
    final log = fileOf('t1');
    log.append(by: ActorKind.agent, actor: 'Agent', op: 'a');
    log.deleteAll();
    expect(log.read(), isEmpty);
    expect(log.latestSeq, 0);
  });
}
