import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/storage/tasks_watch.dart';

/// 盘上的任务清单变了没有。
///
/// 真机 bug：Agent 在外面用 CLI 建了一条任务，**正开着的界面完全不知道**
/// ——列表只在进页面那一刻读过一次。用户看到的是「命令说建好了，界面上
/// 什么都没有」，只能退出去重进。
///
/// 这不是可视模式才需要的：静默模式下人回头来看，也该看得到新任务。
void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('tasks_watch_');
    Directory('${dir.path}/tasks').createSync(recursive: true);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  File task(String id) => File('${dir.path}/tasks/$id.json')
    ..writeAsStringSync('{"id":"$id"}');

  test('多了一条任务 → 指纹变了', () {
    final before = tasksFingerprint(dir);
    task('a');
    expect(tasksFingerprint(dir), isNot(before));
  });

  test('少了一条也算变——别人删了任务，界面该跟着少', () {
    task('a');
    task('b');
    final before = tasksFingerprint(dir);
    File('${dir.path}/tasks/b.json').deleteSync();
    expect(tasksFingerprint(dir), isNot(before));
  });

  test('改了内容也算变——Agent 挑完镜头，封面和状态都该跟着更新', () {
    final f = task('a');
    final before = tasksFingerprint(dir);
    // 文件系统时间戳精度有限，直接改长度更可靠
    f.writeAsStringSync('{"id":"a","name":"改过了"}');
    expect(tasksFingerprint(dir), isNot(before));
  });

  test('什么都没动就不变——不能每一轮都当成变了，那会一直重刷列表', () {
    task('a');
    expect(tasksFingerprint(dir), tasksFingerprint(dir));
  });

  test('目录不存在时给一个稳定值，不炸', () {
    final empty = Directory.systemTemp.createTempSync('tasks_watch_empty_');
    expect(tasksFingerprint(empty), tasksFingerprint(empty));
    empty.deleteSync();
  });

  test('只看任务文件，别的文件不算', () {
    task('a');
    final before = tasksFingerprint(dir);
    File('${dir.path}/tasks/.DS_Store').writeAsStringSync('x');
    expect(tasksFingerprint(dir), before);
  });
}
