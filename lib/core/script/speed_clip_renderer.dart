import '../ffmpeg/rendered_cache.dart';

/// 变速镜头的预渲染切片：EDL 没有逐段倍速（见 Edl 注释），非 1x 的镜头
/// 要先渲成「从框选起点开始、时长恰为分配时长」的对齐切片再进预览轨。
///
/// 按内容指纹缓存（素材 id + 框选 + 分配 + 速度）：改了才重渲，
/// 反复进出预览不重跑 ffmpeg（最高准则：不做一次性的脏活）。
class SpeedClipRenderer {
  final RenderedCache cache;

  SpeedClipRenderer({required this.cache});

  /// 切片末尾多补的那点画面（秒）。
  ///
  /// **切片实际长度必须 ≥ 它在轨上声明的长度**，这是一条硬约束：EDL 段
  /// 声明多长，播放器就按多长排后面的段；文件不够长就提前收，画面轨从此
  /// 一路偏快，而口播轨是按声明长度精确铺的——两条轨越走越错，跟随轨被
  /// 反复往前拽，听感就是声音忽大忽小、严重时卡住反复念同几个字
  /// （真机踩过：5 个切片各短 15~49ms，累计 135ms 就够反复越过纠偏阈值）。
  ///
  /// 而视频时长只能是帧的整数倍、`allocMs` 是任意毫秒数，两者不可能精确
  /// 相等——所以只能往长了补：末尾克隆最后一帧多铺 0.3 秒，让 EDL 按声明
  /// 长度截取时总有画面可播。导出侧一直是这么做的（见 ExportCommands 的
  /// 「变速之后仍然 tpad」），预览这边漏了，于是只有预览会错位
  static const _tailPadSeconds = 0.3;

  /// 渲一个变速切片，返回本地路径。切片无声（镜头本来就不带原声进成片）。
  Future<String> render({
    required int materialId,
    required String sourcePath,
    required int trimStartMs,
    required int allocMs,
    required double speed,
  }) =>
      cache.render(
        // v2：补尾之前渲出来的切片都短几帧，指纹换掉才不会复用到那些坏切片
        key: 'v2|$materialId|$trimStartMs|$allocMs|$speed|$sourcePath',
        prefix: 'clip_$materialId',
        extension: 'mp4',
        what: '变速切片（素材 $materialId，${speed}x）',
        args: (out) => [
          '-y', '-loglevel', 'error',
          // -ss 在 -i 前：按关键帧快速定位，几秒的切片不值得逐帧精确寻址
          '-ss', (trimStartMs / 1000).toStringAsFixed(3),
          '-t', (allocMs * speed / 1000).toStringAsFixed(3),
          '-i', sourcePath,
          '-vf', 'setpts=PTS/$speed,'
              'tpad=stop_mode=clone:stop_duration=$_tailPadSeconds',
          '-an',
          out,
        ],
      );
}
