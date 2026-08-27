import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/storage/doc_watch.dart';

/// 这个任务在盘上变了没有。
///
/// 两个真机问题都出在这儿：
///
/// 1. **假阳性丢写**：Agent 可视模式改台词，界面被唤醒打开时内存里是旧
///    数据，之后界面任何一次自动保存都把旧的盖回去——CLI 报 ok，盘上没变
/// 2. **界面不跟随数据**：Agent 改了什么，界面完全不刷新，人「在旁边看着，
///    看到的是一块黑板」
void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('doc_watch_');
    Directory('${dir.path}/tasks').createSync(recursive: true);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  File task(String id, String body) =>
      File('${dir.path}/tasks/$id.json')..writeAsStringSync(body);

  test('内容变了 → 指纹变', () {
    final f = task('a', '{"id":"a"}');
    final before = taskFingerprint(dir, 'a');
    f.writeAsStringSync('{"id":"a","name":"改过"}');
    expect(taskFingerprint(dir, 'a'), isNot(before));
  });

  test('没动就不变——每轮都当成变了会一直重刷界面', () {
    task('a', '{"id":"a"}');
    expect(taskFingerprint(dir, 'a'), taskFingerprint(dir, 'a'));
  });

  test('只看这一个任务，别的任务变了不算', () {
    task('a', '{"id":"a"}');
    final before = taskFingerprint(dir, 'a');
    task('b', '{"id":"b"}');
    expect(taskFingerprint(dir, 'a'), before);
  });

  test('文件不在时给稳定值，不炸', () {
    expect(taskFingerprint(dir, '没有'), taskFingerprint(dir, '没有'));
  });
}
