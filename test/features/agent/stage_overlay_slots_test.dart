import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/agent/presence_slots.dart';

/// 播报条读不到 Agent 在干什么——真机上编导台跑 `script shots --visual`，
/// 在场文件明明写着「正在给第 6 行找镜头」，底部一条播报都没有。
///
/// 原因是扫 presence 目录时把**所有** `.json` 都当成了任务 id，
/// 包括回执文件、请求结果这类同住一个目录的旁支文件。
void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('slots');
    Directory('${dir.path}/presence').createSync();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  void touch(String name) =>
      File('${dir.path}/presence/$name').writeAsStringSync('{}');

  test('只认在场文件，旁支文件不算任务', () {
    touch('t1.json');
    touch('t2.json');
    touch('t1.ack.json');
    touch('__app__.request-result.json');
    touch('说明.txt');

    expect(presenceTaskIds(dir).toSet(), {'t1', 't2'});
  });

  test('目录不存在时不炸，返回空', () {
    expect(presenceTaskIds(Directory('${dir.path}/没有这个')), isEmpty);
  });
}
