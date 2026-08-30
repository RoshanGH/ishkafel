import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// CLI → GUI 的「唤醒请求」：打开某个任务（工作台或审核模式）。
///
/// 为什么用文件而不是启动参数：`open -a … --args` 的参数**只在冷启动时
/// 生效**——app 已经在跑时 macOS 只把窗口调到前台，参数被丢弃。真机上
/// 撞到过：人从审核页退出后再跑 `ishkafel review`，app 亮了一下，什么都
/// 没发生，而且没有任何报错。
///
/// 文件没有这个问题：CLI 写、GUI 轮询读（读到即删），冷启动热启动同一条
/// 路。这也和任务数据的哲学一致——两个进程之间只共享盘上的文件，不搞
/// 进程间通信。
class UiWakeRequest {
  final String taskId;

  /// true = 进审核模式；false = 进工作台/编导台（按任务类型自动选）
  final bool review;

  /// 明确要去哪个模块：`workbench` / `director` / `review`。
  ///
  /// **这是全软件导航的那一层**：Agent 说去哪，界面负责怎么去——没开就
  /// 拉起来、人停在别的页面就先退回来、再进目标模块。各模块只声明自己
  /// 能被导航到哪儿，不给每个模块各写一套跳转。
  /// null = 按老规矩来（review 标志 + 任务类型）
  final String? module;

  const UiWakeRequest({
    required this.taskId,
    required this.review,
    this.module,
  });
}

File _wakeFile(Directory dataDir) => File(p.join(dataDir.path, 'ui_wake.json'));

void writeUiWake(
  Directory dataDir,
  String taskId, {
  required bool review,
  String? module,
}) {
  _wakeFile(dataDir)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(jsonEncode({
      'task': taskId,
      'review': review,
      'module': ?module,
      'at': DateTime.now().toIso8601String(),
    }));
}

/// 取一条唤醒请求并**删掉文件**——同一条请求只处理一次，
/// 不然 GUI 每次轮询都会再开一个页面
UiWakeRequest? consumeUiWake(Directory dataDir) {
  final file = _wakeFile(dataDir);
  if (!file.existsSync()) return null;
  try {
    final raw = jsonDecode(file.readAsStringSync());
    file.deleteSync();
    if (raw is! Map) return null;
    final task = raw['task'];
    if (task is! String || task.isEmpty) return null;
    return UiWakeRequest(
      taskId: task,
      review: raw['review'] == true,
      module: raw['module'] is String ? raw['module'] as String : null,
    );
  } catch (_) {
    // 文件坏了就删掉当没有——留着它每次轮询都炸一遍
    try {
      file.deleteSync();
    } catch (_) {}
    return null;
  }
}
