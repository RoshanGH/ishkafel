import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/task_view.dart';

import '../support/seed_task.dart';
import 'dart:io';

void main() {
  late Directory dataDir;
  setUp(() => dataDir = Directory.systemTemp.createTempSync('ishkafel_sig'));
  tearDown(() => dataDir.deleteSync(recursive: true));

  test('task 里只留一句信号和一条去处，不留细节', () async {
    final task = await seedTask(dataDir);
    final sub = taskToJson(task)['subtitle'] as Map<String, dynamic>;
    expect(sub.keys,
        containsAll(['shotsWith', 'shotsWithout', 'handEdited', 'suspect']));
    expect(sub['note'], contains('ishkafel subtitle'),
        reason: '不给它去处，它永远不知道该敲哪条命令');
    expect(sub.containsKey('shots'), isFalse,
        reason: 'task 是现状概览，不是数据倾倒场——'
            '#1 那条任务 units 已经占了 17KB 的 99.8%');
  });

  test('算不准时不许炸、也不许报假的计数', () async {
    final task = await seedTask(dataDir);
    // seedTask 只创建最小化任务，units 为 null，整体替换段检查会失败
    // 应该返回一个有 note 指向去处的信号，而不是炸或返回 null
    final sub = taskToJson(task)['subtitle'] as Map<String, dynamic>?;
    expect(sub, isNotNull, reason: '算不准也要返回信号');
    expect(sub!['note'], isNotNull, reason: 'note 一律要给');
    expect(sub['note'], contains('ishkafel subtitle'),
        reason: 'note 要给去处');
  });
}
