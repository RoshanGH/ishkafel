import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/storage/doc_watch.dart';

/// 界面写盘前先看一眼：**盘上被别人改过了吗**。
///
/// 真机连续两轮都栽在这里。界面写盘写的是内存里的整份数据，
/// 而 Agent 在外面也在写同一个文件。谁后写谁赢，于是：
///
/// - Agent 刚写的被界面盖掉（CLI 报 ok、盘上没变）
/// - 更糟的是**已经落盘很久的数据被回滚**——验收 Agent 实测到，
///   它写第二句时把第一句冲没了，而 CLI 全程 `ok:true`
///
/// 上一版靠「Agent 在场时界面不写」挡，但「在场」是 500ms 轮询出来的，
/// 那个窗口里界面照写不误。所以改成**按内容判定**：写之前比一眼指纹，
/// 对不上就不写、去重读。这不依赖任何时序。
void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('safe_save_');
    Directory('${dir.path}/tasks').createSync(recursive: true);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  File write(String id, String body) =>
      File('${dir.path}/tasks/$id.json')..writeAsStringSync(body);

  test('从加载到写盘之间没人动过 → 可以写', () {
    write('a', '{"v":1}');
    final loaded = taskFingerprint(dir, 'a');
    expect(canOverwrite(dir, 'a', loaded), isTrue);
  });

  test('中间被别人改过 → 不许写，得先重读', () {
    write('a', '{"v":1}');
    final loaded = taskFingerprint(dir, 'a');
    write('a', '{"v":2,"更长了":true}');
    expect(canOverwrite(dir, 'a', loaded), isFalse,
        reason: '照写就会把别人刚写的盖掉——真机上连着两轮都栽在这儿');
  });

  test('还没加载过（基线为 null）就放行——新建任务的第一次写', () {
    expect(canOverwrite(dir, 'a', null), isTrue);
  });

  test('文件还不存在 → 放行，这是第一次落盘', () {
    expect(canOverwrite(dir, '新任务', 'none'), isTrue);
  });
}
