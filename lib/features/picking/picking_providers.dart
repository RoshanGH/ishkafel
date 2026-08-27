import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 把素材本体取到**这个任务名下**，返回本地路径。
///
/// 带 taskId 是因为物料按项目存：素材落在 `materials/<taskId>/`，
/// 删任务时跟着一起走。此前它在跨任务共享的 `material_cache/` 里，
/// 任务删了没人收，盘上永远躺着一批不知道归谁的文件。
///
/// 和导出用的是同一个实现、同一个目录（见 `main.dart`）——挑素材时下好，
/// 导出时就不用再下一遍。为 null 表示这台机器上没接（测试环境）。
final materialFetcherProvider = Provider<
    Future<String> Function(String taskId, int candidateId)?>((ref) => null);
