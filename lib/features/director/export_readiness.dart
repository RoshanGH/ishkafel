import '../picking/picked_media_cache.dart';

/// 导出要用到的一项素材（画面素材或配乐曲子）
typedef MediaNeed = ({int id, String name, bool isBgm});

/// 一项下不下来的素材：名字与**能照做的原因**都要给到人
typedef MediaBlocked = ({int id, String name, String reason, bool isBgm});

/// 素材齐没齐的一次盘点
class MediaReadiness {
  /// 已经在本地的项数
  final int ready;

  /// 还在下（或刚排上队）的项数——**等它，不要把人赶回去**
  final int pending;

  /// 下不下来的那些——只有这种情况才该中断导出
  final List<MediaBlocked> failed;

  const MediaReadiness({
    required this.ready,
    required this.pending,
    required this.failed,
  });

  /// 可以开导了：一件没缺、也没有在下的
  bool get canExport => pending == 0 && failed.isEmpty;

  int get total => ready + pending + failed.length;
}

/// 盘点这批素材在本地的情况。
///
/// [statusOf] 给 null 表示这一项没有下载器托管（比如测试环境、或参考段
/// 用的是原片）——当作已就绪，交给导出前的最后一道闸按「本地文件在不在」
/// 判定，这里不臆断。
MediaReadiness checkMedia(
  List<MediaNeed> needs, {
  required PickedMediaStatus? Function(MediaNeed need) statusOf,
  required String? Function(MediaNeed need) failureOf,
}) {
  var ready = 0;
  var pending = 0;
  final failed = <MediaBlocked>[];
  for (final need in needs) {
    switch (statusOf(need)) {
      case PickedMediaStatus.ready:
      case null:
        ready++;
      case PickedMediaStatus.failed:
        failed.add((
          id: need.id,
          name: need.name,
          reason: failureOf(need) ?? '下载失败',
          isBgm: need.isBgm,
        ));
      case PickedMediaStatus.downloading:
      case PickedMediaStatus.absent:
        pending++;
    }
  }
  return MediaReadiness(ready: ready, pending: pending, failed: failed);
}
