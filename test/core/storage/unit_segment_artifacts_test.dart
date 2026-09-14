import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/storage/task_artifacts.dart';
import 'package:path/path.dart' as p;

/// 切一段底片会在 analysis_work 里留下采信号和复核帧。
/// **它们必须跟着任务一起被清掉**——不然每切一段就留一堆没人认领的文件。
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('seg_art'));
  tearDown(() => dir.deleteSync(recursive: true));

  File work(String name) {
    final f = File(p.join(dir.path, 'analysis_work', name));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync('x' * 1024);
    return f;
  }

  test('切一段底片留下的中间产物算在这条任务名下', () {
    // UnitSegmenter 用的 key 是 `<taskId>_u<uid>`，抽信号/复核帧照着它起名
    work('t1_uabc_scene.txt');
    work('t1_uabc_thumbs.raw');
    work('t1_uabc_rev1200.jpg');

    final mine = TaskArtifacts(dir)
        .of('t1')
        .map((e) => p.basename(e.path))
        .toList()
      ..sort();

    expect(mine, [
      't1_uabc_rev1200.jpg',
      't1_uabc_scene.txt',
      't1_uabc_thumbs.raw',
    ], reason: '三份都要算在这条任务名下，删任务时才会跟着走');
  });

  test('删任务时一起清掉，不留孤儿', () {
    work('t1_uabc_scene.txt');
    work('t1_uabc_rev1200.jpg');
    work('t2_uzzz_scene.txt');

    final artifacts = TaskArtifacts(dir);
    artifacts.delete(artifacts.of('t1'));

    final left = Directory(p.join(dir.path, 'analysis_work'))
        .listSync()
        .map((e) => p.basename(e.path))
        .toList();
    expect(left, ['t2_uzzz_scene.txt'], reason: '别人的一个都不能动');
  });

  test('任务 id 是另一个的前缀时不误删', () {
    work('t1_uabc_scene.txt');
    work('t12_uabc_scene.txt');

    final artifacts = TaskArtifacts(dir);
    artifacts.delete(artifacts.of('t1'));

    final left = Directory(p.join(dir.path, 'analysis_work'))
        .listSync()
        .map((e) => p.basename(e.path))
        .toList();
    expect(left, ['t12_uabc_scene.txt']);
  });
}
