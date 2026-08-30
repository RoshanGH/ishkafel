import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/storage/agent_request.dart';
import 'package:ishkafel/core/storage/ui_action.dart';

/// 界面正开着这条任务时，`export` 一度直接拒绝：
/// 「gui:76018 正在操作这个任务，导不了」，退出码 4。
///
/// 这是 `apply plans` 修过的那个死结在导出这条路上的原样重现：**可视模式
/// 要求界面停在这个任务上，而导出要求界面不能停在这个任务上**。
/// 于是人最想看着的一步（导出，分钟级、直接产出交付物），
/// 恰恰因为「人在看」而做不了。
///
/// 和提交方案不一样的是：导出跑几分钟，硬塞进 90 秒回执的通道不合适，
/// 而且它花钱花时间——**人在旁边时让他点一下确认反而是对的**。
/// 所以委派的是「把导出对话框打开、参数填好」，最后那一下由人点。
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('exp_del'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('有「打开导出」这个界面动作', () {
    expect(UiAction.parse('export.open'), UiAction.exportOpen);
    expect(UiAction.exportOpen.label, contains('导出'));
  });

  test('下单时把导出规格一起带上——人不用再填一遍', () {
    final id = writeAgentRequest(
      dataDir: dir,
      taskId: 't1',
      kind: UiAction.exportOpen.wire,
      payload: {'outputDir': '/tmp/out', 'resolution': '1080'},
    );
    final req = consumeAgentRequest(dataDir: dir, taskId: 't1');
    expect(req?.id, id);
    expect(req?.payload['outputDir'], '/tmp/out');
    expect(req?.payload['resolution'], '1080');
  });
}
