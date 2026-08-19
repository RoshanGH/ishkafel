import '../ffmpeg/rendered_cache.dart';

/// 变速镜头的预渲染切片：EDL 没有逐段倍速（见 Edl 注释），非 1x 的镜头
/// 要先渲成「从框选起点开始、时长恰为分配时长」的对齐切片再进预览轨。
///
/// 按内容指纹缓存（素材 id + 框选 + 分配 + 速度）：改了才重渲，
/// 反复进出预览不重跑 ffmpeg（最高准则：不做一次性的脏活）。
class SpeedClipRenderer {
  final RenderedCache cache;

  SpeedClipRenderer({required this.cache});

  /// 渲一个变速切片，返回本地路径。切片无声（镜头本来就不带原声进成片）。
  Future<String> render({
    required int materialId,
    required String sourcePath,
    required int trimStartMs,
    required int allocMs,
    required double speed,
  }) =>
      cache.render(
        key: '$materialId|$trimStartMs|$allocMs|$speed|$sourcePath',
        prefix: 'clip_$materialId',
        extension: 'mp4',
        what: '变速切片（素材 $materialId，${speed}x）',
        args: (out) => [
          '-y', '-loglevel', 'error',
          // -ss 在 -i 前：按关键帧快速定位，几秒的切片不值得逐帧精确寻址
          '-ss', (trimStartMs / 1000).toStringAsFixed(3),
          '-t', (allocMs * speed / 1000).toStringAsFixed(3),
          '-i', sourcePath,
          '-vf', 'setpts=PTS/$speed',
          '-an',
          out,
        ],
      );
}
