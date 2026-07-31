import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/tasks/task_artifact_cleaner.dart';

void main() {
  late Directory tempDir;
  late Directory coversDir;
  late Directory workDir;
  late FileTaskArtifactCleaner cleaner;

  Future<File> touch(Directory dir, String name) async {
    final file = File('${dir.path}/$name');
    await file.create(recursive: true);
    await file.writeAsString('x');
    return file;
  }

  /// 目录里剩下的文件名（排序后便于逐项比对）
  Future<List<String>> names(Directory dir) async {
    final entities = await dir.list().toList();
    return entities.map((e) => e.path.split('/').last).toList()..sort();
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ishkafel_cleanup_');
    coversDir = Directory('${tempDir.path}/covers');
    workDir = Directory('${tempDir.path}/analysis_work');
    await coversDir.create(recursive: true);
    await workDir.create(recursive: true);
    cleaner = FileTaskArtifactCleaner(coversDir: coversDir, workDir: workDir);
  });

  tearDown(() async => tempDir.delete(recursive: true));

  test('删除封面与该任务的全部分析中间产物', () async {
    final cover = await touch(coversDir, 'ab.jpg');
    final pcm = await touch(workDir, 'ab.pcm');
    final shot = await touch(workDir, 'ab_shot0.jpg');
    final thumb = await touch(workDir, 'ab_tl_3.jpg');

    await cleaner.cleanup('ab');

    expect(await cover.exists(), isFalse);
    expect(await pcm.exists(), isFalse);
    expect(await shot.exists(), isFalse);
    expect(await thumb.exists(), isFalse);
  });

  test('不误删 id 只是前缀相同的其他任务产物', () async {
    final other = await touch(workDir, 'abc.pcm');
    final otherCover = await touch(coversDir, 'abc.jpg');

    await cleaner.cleanup('ab');

    expect(await other.exists(), isTrue);
    expect(await otherCover.exists(), isTrue);
  });

  test('目录整个不存在时静默通过，且不会把目录建出来', () async {
    final missingCovers = Directory('${tempDir.path}/nope_covers');
    final missingWork = Directory('${tempDir.path}/nope_work');
    final empty = FileTaskArtifactCleaner(
      coversDir: missingCovers,
      workDir: missingWork,
    );

    await empty.cleanup('ab');

    expect(await missingCovers.exists(), isFalse,
        reason: '清理不该反过来创建目录');
    expect(await missingWork.exists(), isFalse);
  });

  test('清理一个从不存在的任务：不抛异常，也不碰其他任务的产物', () async {
    final other = await touch(workDir, 'zz.pcm');
    final otherCover = await touch(coversDir, 'zz.jpg');

    await cleaner.cleanup('never-existed');

    expect(await other.exists(), isTrue);
    expect(await otherCover.exists(), isTrue);
    expect(await names(workDir), ['zz.pcm']);
    expect(await names(coversDir), ['zz.jpg']);
  });

  test('重复清理同一任务结果一致（幂等），第二次同样不波及其他任务', () async {
    await touch(coversDir, 'ab.jpg');
    await touch(workDir, 'ab.pcm');
    await touch(workDir, 'ab_shot0.jpg');
    await touch(workDir, 'abc.pcm');
    await touch(coversDir, 'abc.jpg');

    await cleaner.cleanup('ab');
    final afterFirst = (work: await names(workDir), covers: await names(coversDir));

    await cleaner.cleanup('ab');
    final afterSecond = (work: await names(workDir), covers: await names(coversDir));

    expect(afterFirst.work, ['abc.pcm']);
    expect(afterFirst.covers, ['abc.jpg']);
    expect(afterSecond.work, afterFirst.work, reason: '第二次清理必须是空操作');
    expect(afterSecond.covers, afterFirst.covers);
  });
}
