import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/storage/media_migration.dart';
import 'package:ishkafel/core/storage/task_media.dart';

/// 把共享缓存里的物料分发到各任务名下。
///
/// **不迁就等于制造孤儿**：改成按任务存之后，老的 `material_cache/`
/// 立刻变成一堆没人认领的文件——正是这次要消灭的东西。
///
/// 迁移只能做一次，而且要能中断重来（磁盘满、进程被杀）。
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('media_mig_');
    Directory('${dir.path}/tasks').createSync(recursive: true);
    Directory('${dir.path}/material_cache').createSync(recursive: true);
    Directory('${dir.path}/bgm_cache').createSync(recursive: true);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  void writeTask(String id, {List<int> materials = const [], List<int> bgm = const []}) {
    File('${dir.path}/tasks/$id.json').writeAsStringSync(jsonEncode({
      'id': id,
      'name': id,
      'status': 'ready',
      'createdAt': '2026-08-26T00:00:00.000Z',
      'updatedAt': '2026-08-26T00:00:00.000Z',
      'units': const [],
      'script': {
        'lines': [
          {
            'id': 'l1',
            'text': '句',
            'shots': [
              for (final m in materials) {'materialId': m, 'name': 'm$m'},
            ],
          }
        ],
        'bgmSegments': [
          for (final b in bgm)
            {
              'startLine': 0,
              'endLine': 0,
              'material': {'id': b, 'name': 'b$b', 'durationMs': 1000},
            },
        ],
      },
    }));
  }

  File cacheFile(String sub, String name, {int bytes = 64}) =>
      File('${dir.path}/$sub/$name')..writeAsBytesSync(List.filled(bytes, 1));

  test('素材按引用分发到用它的那个任务', () async {
    writeTask('t1', materials: [100]);
    cacheFile('material_cache', '100.mp4');

    final r = await migrateSharedMediaToTasks(dir);
    expect(r.moved, 1);
    expect(TaskMedia(dataDir: dir, taskId: 't1').localMaterial(100), isNotNull);
  });

  test('两个任务共用一条素材：各得一份，都能用', () async {
    writeTask('t1', materials: [100]);
    writeTask('t2', materials: [100]);
    cacheFile('material_cache', '100.mp4');

    await migrateSharedMediaToTasks(dir);
    expect(TaskMedia(dataDir: dir, taskId: 't1').localMaterial(100), isNotNull);
    expect(TaskMedia(dataDir: dir, taskId: 't2').localMaterial(100), isNotNull);
  });

  test('没有任何任务引用的素材直接删掉——那正是我们要清的孤儿', () async {
    writeTask('t1', materials: [100]);
    cacheFile('material_cache', '100.mp4');
    cacheFile('material_cache', '999.mp4');

    final r = await migrateSharedMediaToTasks(dir);
    expect(r.orphansRemoved, 1);
    expect(File('${dir.path}/material_cache/999.mp4').existsSync(), isFalse);
  });

  test('配乐同样处理，并保留原扩展名', () async {
    writeTask('t1', bgm: [7]);
    cacheFile('bgm_cache', '7.m4a');

    await migrateSharedMediaToTasks(dir);
    expect(TaskMedia(dataDir: dir, taskId: 't1').localBgm(7), endsWith('7.m4a'));
  });

  test('迁完把空的共享目录收掉——留着下次又会有人往里写', () async {
    writeTask('t1', materials: [100]);
    cacheFile('material_cache', '100.mp4');

    await migrateSharedMediaToTasks(dir);
    expect(Directory('${dir.path}/material_cache').existsSync(), isFalse);
    expect(Directory('${dir.path}/bgm_cache').existsSync(), isFalse);
  });

  test('已经迁过就是空操作，不重复搬', () async {
    writeTask('t1', materials: [100]);
    cacheFile('material_cache', '100.mp4');
    await migrateSharedMediaToTasks(dir);

    final again = await migrateSharedMediaToTasks(dir);
    expect(again.moved, 0);
    expect(again.orphansRemoved, 0);
  });

  test('目标已经有同名文件就跳过，不覆盖——上次迁到一半被杀也能重来', () async {
    writeTask('t1', materials: [100]);
    final target = TaskMedia(dataDir: dir, taskId: 't1');
    target.materialsDir.createSync(recursive: true);
    File(target.materialPath(100)).writeAsBytesSync(List.filled(999, 7));
    cacheFile('material_cache', '100.mp4');

    await migrateSharedMediaToTasks(dir);
    expect(File(target.materialPath(100)).lengthSync(), 999,
        reason: '已经在那儿的是好的，不能被半截文件盖掉');
  });

  test('半截下载（0 字节）不迁，直接当孤儿清掉', () async {
    writeTask('t1', materials: [100]);
    cacheFile('material_cache', '100.mp4', bytes: 0);

    final r = await migrateSharedMediaToTasks(dir);
    expect(TaskMedia(dataDir: dir, taskId: 't1').localMaterial(100), isNull);
    expect(r.moved, 0);
  });

  test('老的派生缓存整个清掉——它们按内容指纹命名，反查不出归谁', () async {
    writeTask('t1', materials: [100]);
    cacheFile('material_cache', '100.mp4');
    Directory('${dir.path}/preview_proxy').createSync();
    File('${dir.path}/preview_proxy/proxy_abc.mp4')
        .writeAsBytesSync(List.filled(64, 1));
    Directory('${dir.path}/material_vocals/114797').createSync(recursive: true);

    final r = await migrateSharedMediaToTasks(dir);
    expect(Directory('${dir.path}/preview_proxy').existsSync(), isFalse);
    expect(Directory('${dir.path}/material_vocals').existsSync(), isFalse);
    expect(r.derivedCleared, greaterThan(0),
        reason: '要如实回报清了多少——它们会重算，但重算要花时间，人该知道');
  });

  test('人声分离模型不能碰——那是工具，不是任务数据', () async {
    Directory('${dir.path}/separator_models').createSync();
    await migrateSharedMediaToTasks(dir);
    expect(Directory('${dir.path}/separator_models').existsSync(), isTrue);
  });

  test('没有共享目录时什么都不做，不炸', () async {
    Directory('${dir.path}/material_cache').deleteSync();
    Directory('${dir.path}/bgm_cache').deleteSync();
    expect((await migrateSharedMediaToTasks(dir)).moved, 0);
  });
}
