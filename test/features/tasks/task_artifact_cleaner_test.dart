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

  test('目录或文件不存在时静默通过（幂等）', () async {
    final empty = FileTaskArtifactCleaner(
      coversDir: Directory('${tempDir.path}/nope_covers'),
      workDir: Directory('${tempDir.path}/nope_work'),
    );
    await empty.cleanup('ab');
    await cleaner.cleanup('never-existed');
  });
}
