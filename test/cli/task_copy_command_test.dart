import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/commands/tasks_command.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

/// 界面上人能复制，Agent 就得能复制。
void main() {
  late Directory dir;
  late FileTaskRepository repo;

  RenewTask task({
    String id = 'src',
    String name = '原任务',
    RenewTaskStatus status = RenewTaskStatus.ready,
  }) =>
      RenewTask(
        id: id,
        seq: 3,
        name: name,
        sourcePath: '/v/a.mp4',
        status: status,
        createdAt: DateTime.utc(2026, 9, 1),
        updatedAt: DateTime.utc(2026, 9, 1),
        units: const [
          SemanticUnit(
              uid: 'u0', index: 0, startMs: 0, endMs: 1000, transcript: 'U1'),
        ],
      );

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('ishkafel_copycmd_');
    repo = FileTaskRepository(dir);
    await repo.save(task());
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<(int, Map<String, dynamic>?, String)> run(
      List<String> rest, {String? name}) async {
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runTaskCopyCommand(
        rest: rest, dataDir: dir, name: name, out: out, err: err);
    final text = out.toString().trim();
    return (
      code,
      text.isEmpty ? null : jsonDecode(text) as Map<String, dynamic>,
      err.toString()
    );
  }

  test('复制出一条新任务：新 id、新编号、名字带「的副本」', () async {
    final (code, json, _) = await run(['src']);
    expect(code, 0);
    expect(json!['name'], '原任务 的副本');
    expect(json['copiedFrom'], 'src');
    expect(json['id'], isNot('src'));
    expect(json['seq'], 4);

    final all = await repo.findAll();
    expect(all, hasLength(2), reason: '原任务要原样留着——复制不是搬家');
  });

  test('--name 自己起名', () async {
    final (code, json, _) = await run(['src'], name: 'B 路线');
    expect(code, 0);
    expect(json!['name'], 'B 路线');
  });

  test('连着复制两次不撞名', () async {
    await run(['src']);
    final (_, json, _) = await run(['src']);
    expect(json!['name'], '原任务 的副本 2');
  });

  test('报出这一下占了多少盘——人和 Agent 都该知道', () async {
    final (_, json, _) = await run(['src']);
    expect(json!.containsKey('bytesCopied'), isTrue);
  });

  test('没有这个任务：说清楚，不是静默成功', () async {
    final (code, json, err) = await run(['不存在']);
    expect(code, isNot(0));
    expect(json, isNull);
    expect(err, contains('没有这个任务'));
  });

  test('还在分析的不给复制——抄出来的副本只有一半产物', () async {
    await repo.save(task(id: 'busy', status: RenewTaskStatus.analyzing));
    final (code, _, err) = await run(['busy']);
    expect(code, isNot(0));
    expect(err, contains('还在分析'));
  });
}
