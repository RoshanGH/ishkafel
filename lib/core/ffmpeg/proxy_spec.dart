import 'media_spec.dart';

/// **预览代理的规格**——一个常量，不从原片探测。
///
/// ## 为什么是常量
///
/// 此前的规矩是「所有素材向原片规格看齐」：读出原片是
/// `hevc / Main 10 / p010le / 1080x1920`，就把每一条候选素材、每一段变速切片
/// 都编成这个规格。它在开发机（Apple Silicon）上成立，换一台机器就崩：
/// **Intel Mac 的 VideoToolbox 绝大多数编不了 10bit HEVC**，
/// `-profile:v main10` 直接失败，素材规格化与变速切片两条路同时断掉。
///
/// 根子上的问题是：原片来自客户、来自剪映导出、来自各种手机，**规格不受我们
/// 控制**，却决定了本机能不能干活。
///
/// 所以反过来——预览链路上的每一段都转成**我们说了算的同一个规格**。这正是
/// 剪映、Final Cut、Premiere 都有的「代理 / 优化媒体」：导入时生成统一规格的
/// 低码率副本，剪辑预览全程用副本，**导出时才回到原始素材**。
///
/// ## 为什么是这个规格
///
/// H.264 High / 8bit / 720×1280：2010 年后的 Mac 全都能硬编硬解，软编
/// （libx264）也快得起来。9:16 竖屏降到 720 宽，预览看清画面绰绰有余，
/// 而解码压力比 1080×1920 的 HEVC Main 10 小一个量级——老机器上预览能不能
/// 跑顺，就差这一步。
///
/// 帧率**跟着原片走**，不写死：帧率一变，时间线上每一帧的位置都要重算，
/// 而本产品所有切分边界都是按帧对齐的。
///
/// ## 边界（必须守住）
///
/// > **代理只用于预览。导出一律走原始素材。**
///
/// 代理是 720p 低码率，拿它导出等于把成片画质砍掉。导出路径必须从任务的
/// `sourcePath` 与 `material_cache/` 的原始下载取，永远不碰代理目录——
/// 这条有测试盯着（见 `export_uses_original_test.dart`）。
abstract final class ProxySpec {
  static const codec = 'h264';

  /// ffprobe 报的是 `High`，ffmpeg 要的是 `high`
  static const profile = 'High';

  static const pixelFormat = 'yuv420p';

  /// 竖屏 9:16。横屏素材会被补黑边到这个画幅（不拉伸变形）
  static const width = 720;
  static const height = 1280;

  /// 预览码率。低于 2M 时快速运动的画面会糊，看不清就失去了预览的意义
  static const bitrate = '3M';

  /// 这一份代理该长什么样。[frameRate] 跟原片走
  static MediaSpec at(String frameRate) => MediaSpec(
        codec: codec,
        profile: profile,
        pixelFormat: pixelFormat,
        width: width,
        height: height,
        frameRate: frameRate,
      );

  /// 这个文件已经是代理规格了吗——是的话一个字节都不用动。
  ///
  /// 帧率不参与比较：代理的帧率本来就是跟着原片定的，比它等于和自己比。
  static bool matches(MediaSpec? spec) =>
      spec != null &&
      spec.codec == codec &&
      spec.pixelFormat == pixelFormat &&
      spec.width == width &&
      spec.height == height;

  /// 转成代理的 ffmpeg 参数。
  ///
  /// 用软编 libx264 而不是 `h264_videotoolbox`：硬编的规格支持是**机器相关**
  /// 的，而这套方案的全部意义就是「不再依赖本机能编什么」。libx264 在
  /// veryfast 下编 720p 足够快，且哪台机器上出来的都一模一样。
  ///
  /// **只动画面**：声音原样拷贝。预览的声音走口播轨与配乐轨，画面轨那一路
  /// 根本不出声（见 MediaKitPlaybackController.setMuted）；重编只会白白损一
  /// 道音质。整体替换要用到候选自带的声音，那一路读的也是这份拷贝。
  static List<String> encodeArgs({
    required String input,
    required String frameRate,
    required String out,
  }) =>
      [
        '-y', '-v', 'error',
        '-i', input,
        '-vf',
        'scale=$width:$height:force_original_aspect_ratio=decrease,'
            'pad=$width:$height:(ow-iw)/2:(oh-ih)/2:black,setsar=1',
        '-r', frameRate,
        '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20',
        '-profile:v', 'high',
        '-pix_fmt', pixelFormat,
        '-b:v', bitrate,
        // 关键帧密一点：预览要频繁 seek，GOP 太长会让每次跳转都等解码
        '-g', '60',
        '-c:a', 'copy',
        out,
      ];
}
