import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 按素材 id 把视频本体取到本地，返回本地路径。
///
/// 和导出用的是同一个实现、同一个缓存目录（见 `main.dart`）——挑素材时下好，
/// 导出时就不用再下一遍。为 null 表示这台机器上没接（测试环境），
/// 此时不做本地固定，预览与导出仍然按 id 现取。
final materialFetcherProvider =
    Provider<Future<String> Function(int candidateId)?>((ref) => null);
