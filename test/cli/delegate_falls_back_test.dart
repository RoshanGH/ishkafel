import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/delegate.dart';
import 'package:ishkafel/core/storage/ui_where.dart';

/// 委派是**首选路径**（人看到的和落盘的同源），不是**必经之路**。
/// 界面不在场时它一秒都不该等——可视化坏掉的最坏后果只能是「这一步没看见」，
/// 不能是「Agent 卡住了」。
void main() {
  late Directory dataDir;
  setUp(() => dataDir = Directory.systemTemp.createTempSync('ishkafel_dlg'));
  tearDown(() => dataDir.deleteSync(recursive: true));

  test('界面不在这条任务上：零等待，直接自己干', () async {
    var triedUi = false;
    final sw = Stopwatch()..start();
    final got = await delegateOrDoItYourself<String>(
      dataDir: dataDir,
      taskId: 't_3',
      viaUi: () async {
        triedUi = true;
        return null;
      },
      myself: () async => '自己干的',
    );
    sw.stop();

    expect(got, '自己干的');
    expect(triedUi, isFalse, reason: '界面都不在，没有委派的理由');
    expect(sw.elapsed, lessThan(const Duration(milliseconds: 500)),
        reason: '界面没开时每条写命令白等 2 秒，47 镜就是一分半');
  });

  test('界面就在这条任务上：走委派', () async {
    writeUiWhere(dataDir, module: 'workbench', taskId: 't_3');
    final got = await delegateOrDoItYourself<String>(
      dataDir: dataDir,
      taskId: 't_3',
      viaUi: () async => '界面干的',
      myself: () async => '自己干的',
    );
    expect(got, '界面干的');
  });

  test('界面在，但没应：兜底自己干，绝不报失败', () async {
    writeUiWhere(dataDir, module: 'workbench', taskId: 't_3');
    final got = await delegateOrDoItYourself<String>(
      dataDir: dataDir,
      taskId: 't_3',
      viaUi: () async => null,      // 界面没接单
      myself: () async => '自己干的',
    );
    expect(got, '自己干的');
  });

  test('界面在别的任务上：也不等它', () async {
    writeUiWhere(dataDir, module: 'workbench', taskId: 't_10');
    var triedUi = false;
    final got = await delegateOrDoItYourself<String>(
      dataDir: dataDir,
      taskId: 't_3',
      viaUi: () async {
        triedUi = true;
        return null;
      },
      myself: () async => '自己干的',
    );
    expect(triedUi, isFalse);
    expect(got, '自己干的');
  });
}
