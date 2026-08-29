import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/commands/clean_command.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

/// Agent 跑久了会在盘上攒下几个 G——素材、切片、抽帧、导出中间产物，
/// 全是它自己造的。而「清理残留产物」一直只有界面能点。
///
/// 自查时磁盘上量到 5.7G；虽然当时没有孤儿（任务都还在），
/// 但一旦删过任务、或者中转文件积起来，Agent 收不掉自己造的东西。
void main() {
  late Directory dir;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('clean');
    await FileTaskRepository(dir).save(RenewTask(
      id: 'live',
      name: '活着的任务',
      status: RenewTaskStatus.ready,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    ));
    // 一个属于已删任务的目录（孤儿），一个属于现存任务的（不能动）
    for (final p in ['materials/dead/x.mp4', 'materials/live/y.mp4']) {
      final f = File('${dir.path}/$p')..parent.createSync(recursive: true);
      f.writeAsStringSync('data');
    }
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Map<String, dynamic> decode(StringBuffer o) =>
      jsonDecode(o.toString()) as Map<String, dynamic>;

  test('先看会删什么，不直接动手', () async {
    final out = StringBuffer();
    final code = await runCleanCommand(
      rest: const [],
      dataDir: dir,
      out: out,
      err: StringBuffer(),
    );

    expect(code, 0);
    expect(decode(out)['orphanCount'], greaterThan(0));
    expect(File('${dir.path}/materials/dead/x.mp4').existsSync(), isTrue,
        reason: '没给 --yes 就不该真删——删了没法撤回');
    expect('${decode(out)['next']}', contains('--yes'));
  });

  test('--yes 才真删，而且只删没主的', () async {
    final out = StringBuffer();
    await runCleanCommand(
      rest: const [],
      dataDir: dir,
      confirmed: true,
      out: out,
      err: StringBuffer(),
    );

    expect(File('${dir.path}/materials/dead/x.mp4').existsSync(), isFalse);
    expect(File('${dir.path}/materials/live/y.mp4').existsSync(), isTrue,
        reason: '活着的任务的东西一个都不能碰');
  });

  test('报的是条数和释放的兆数，别把字节数当条数', () async {
    final out = StringBuffer();
    await runCleanCommand(
        rest: const [], dataDir: dir, confirmed: true,
        out: out, err: StringBuffer());

    final json = decode(out);
    expect(json['removedItems'], greaterThan(0));
    expect(json['removedItems'], lessThan(100),
        reason: '条数不该是个天文数字——那说明报的其实是字节数');
  });

  test('没什么可清时明说，不装作干了活', () async {
    await runCleanCommand(
        rest: const [], dataDir: dir, confirmed: true,
        out: StringBuffer(), err: StringBuffer());

    final out = StringBuffer();
    await runCleanCommand(
        rest: const [], dataDir: dir, out: out, err: StringBuffer());

    expect(decode(out)['orphanCount'], 0);
    expect('${decode(out)['next']}', contains('没什么可清'));
  });
}
