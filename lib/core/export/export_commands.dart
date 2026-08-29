import '../ffmpeg/media_spec.dart';
import '../subtitle/subtitle_overlay.dart';
import 'export_spec.dart';
import 'speed_fit.dart';

/// 导出用的 ffmpeg 命令行拼装（纯函数，不起进程）。
///
/// 拆出来单独放是因为这一层最容易出隐蔽错误：参数顺序错一个位置、少一个
/// `-y`，表现都是「导出失败」四个字，而真正的原因埋在几百行 ffmpeg 日志里。
/// 做成纯函数就能一条条钉住。
///
/// **成片的构成**：画面来自候选素材或原片，**声音一律来自原片**（或换音色后
/// 的配音）。产品要的是「结构相同但画面全新」——台词不变、画面全换，所以候选
/// 素材自带的旁白必须丢掉，只取它的画面。
class ExportCommands {
  ExportCommands._();

  /// 成片规格。竖屏 9:16 是本产品的主要工作对象；统一到同一套参数，
  /// 拼接时才不会因为分辨率/帧率/编码不一致而失败或花屏。
  static const int width = 1080;
  static const int height = 1920;
  static const int fps = 30;
  static const int audioSampleRate = 48000;

  /// 一段该有多少帧。时长不是帧长的整数倍时四舍五入——同一段的画面与声音
  /// 都按这个帧数对齐，两边就不会各走各的。
  static int frameCount(int durationMs, {double? atFps}) =>
      (durationMs * ((atFps ?? 0) > 0 ? atFps! : fps) / 1000).round();

  /// 这一段实际会有多长（帧数决定的真实时长，毫秒）
  /// 这一段的**精确秒数**（按整帧对齐）。
  ///
  /// 声音与画面必须用**同一个帧率**算，否则两边各自取整，每段差出小半帧、
  /// 一路累积到片尾就是可听见的错位。所以选了 60fps 导出时，这里也要按 60 算
  static double exactSeconds(int durationMs, {double? atFps}) {
    final rate = (atFps ?? 0) > 0 ? atFps! : fps.toDouble();
    return frameCount(durationMs, atFps: rate) / rate;
  }

  /// 把原片的一段切出来，规格归一到成片标准（**丢掉声音**，声音单独成轨）。
  ///
  /// `-ss` 放在 `-i` 之前是快速定位（关键帧级）；这里要的是精确切割，所以
  /// 放在 `-i` 之后——慢一些，但切点准。
  ///
  /// 更要紧的是 `-frames:v`：只给起止时间的话，输出帧数由编码器凑整，每段
  /// 会多出或少掉几毫秒。50 个镜头累计下来就是几百毫秒，画面与声音在片尾
  /// 明显对不上。锁死帧数，每一段就都是可预期的长度。
  static List<String> trimOriginalVideo({
    required String source,
    required int startMs,
    required int endMs,
    required String out,
    ExportSpec? spec,
  }) =>
      [
        '-y', '-v', 'error',
        '-i', source,
        '-ss', _seconds(startMs),
        // 多给两帧余量，真正的长度由 -frames:v 定
        '-to', _seconds(endMs + (2000 / (spec?.fps ?? fps)).round()),
        '-an',
        ..._videoNormalize(spec),
        // **按导出帧率数帧**：选了 60fps 而这里还按 30 算，切出来的片段
        // 只有一半长，后面所有段跟着错位
        '-frames:v',
        '${frameCount(endMs - startMs, atFps: (spec?.fps ?? fps).toDouble())}',
        out,
      ];

  /// 整体替换的那一段画面：**原样接上**，只做分辨率/帧率归一。
  ///
  /// 不加速不放慢不裁不补——整体替换换的是「这一整段」，时长随候选，
  /// 后面所有单元跟着后移。对齐到原坑位是镜头替换该干的事。
  static List<String> wholeReplacementVideo({
    required String input,
    required String out,
    ExportSpec? spec,
  }) =>
      [
        '-y', '-v', 'error',
        '-i', input,
        '-an',
        '-vf', _scalePad(null, spec),
        '-r', '${spec?.fps ?? fps}',
        ...(spec ?? const ExportSpec()).encodeArgs,
        '-pix_fmt', 'yuv420p',
        out,
      ];

  /// 把一条候选素材套进这一段的时长。
  ///
  /// 给了 [candidateDurationMs] 就**变速**填满（镜头替换的规格：只换画面、
  /// 口播不动，所以画面必须严丝合缝地对齐原坑位）。倍率与允许范围见
  /// [SpeedFit]，越界的在导出前就该被拦下，这里不再判断。
  ///
  /// 不给 [candidateDurationMs] 时退回老做法——比目标长就裁、短就**冻结
  /// 最后一帧补齐**。不循环播放：三秒的坑位放一段两秒的素材，循环会看到画面
  /// 突然跳回开头，观众一眼看出是拼的；冻帧至少像「这个镜头多停了一会儿」。
  ///
  /// 变速之后仍然 tpad + `-frames:v`：倍率是浮点数，舍入之后可能差最后一两
  /// 帧，差一帧后面每一段都往前挪。
  static List<String> fitCandidateVideo({
    required String input,
    required int durationMs,
    required String out,
    int? candidateDurationMs,

    /// 从素材的第几毫秒开始截。
    ///
    /// **不给 = 整条压缩**（老行为）：20 秒的素材塞进 0.5 秒的坑位就是 40 倍
    /// 快放。真机上将近四成的坑位不到 1.5 秒，而素材库里的分镜普遍 4~30 秒，
    /// 那些镜头必然是一串快进。给了起点就只截坑位那么长的一段，倍速回到 1.0
    /// ——人拿剪辑软件做这件事就是这么做的。
    int? trimStartMs,

    /// 要叠在这段切片上的字幕图（镜头替换保留台词字幕用，见
    /// subtitle_overlay.dart）。叠加发生在归一、变速、补帧**之后**：
    /// 显隐时间按切片输出时间轴算，位置随图（图与输出同分辨率）。
    /// 用 overlay 而不是 ass/drawtext——那两个滤镜依赖 libass/freetype，
    /// 新版 Homebrew 的 ffmpeg 已经不带
    List<SubtitleOverlayImage> subtitleOverlays = const [],

    /// 编成什么规格。**预览必须传原片的规格**：预览是把原片与这段切片拼成
    /// 一条 EDL 播，中间换一次编码，播放器就要重建一次解码器——用户看到的
    /// 是「突然加速、突然变慢」（真机实测，与素材规格不一致时同一个毛病）。
    MediaSpec? target,

    /// 导出时传：分辨率/帧率/码率/编码器全跟用户选的规格走。
    /// 曾经不传吃死值（1080×1920/30fps/H.264），同一条 concat 清单里
    /// 原片段是新规格、这段是死值——`-c copy` 拼接轻则花屏重则失败。
    /// 与 [target] 互斥：预览传 target、导出传 spec；都传时以 target 为准
    ExportSpec? spec,
  }) {
    // 截了一段等长的就不再变速——截完还变速等于白截
    final trimmed = trimStartMs != null &&
        candidateDurationMs != null &&
        candidateDurationMs - trimStartMs >= durationMs;
    final factor = candidateDurationMs == null || trimmed
        ? 1.0
        : SpeedFit.factorFor(
            candidateMs: candidateDurationMs, slotMs: durationMs);
    // 一样长时不插滤镜：白走一道只会掉画质
    final speed = (factor - 1).abs() < 1e-6
        ? ''
        : ',setpts=PTS/${_trim(factor)}';
    final effectiveSpec = target == null ? spec : null;
    final baseChain = '${_scalePad(target, effectiveSpec)}$speed'
        ',tpad=stop_mode=clone:stop_duration=${_seconds(durationMs)}';
    final outFps = target?.fps ?? effectiveSpec?.fps.toDouble();
    return [
      '-y', '-v', 'error',
      // -ss 摆在 -i 前面：放后面是解码完再丢，从 20 秒素材里取 0.5 秒
      // 要白解 19.5 秒
      if (trimmed) ...['-ss', _seconds(trimStartMs!)],
      '-i', input,
      for (final o in subtitleOverlays) ...['-i', o.pngPath],
      '-an',
      if (subtitleOverlays.isEmpty) ...[
        '-vf', baseChain,
      ] else ...[
        '-filter_complex',
        subtitleFilterComplex(baseChain: baseChain, overlays: subtitleOverlays),
        '-map', subtitleFilterOutLabel(subtitleOverlays.length),
      ],
      '-r', target?.frameRate ?? '${effectiveSpec?.fps ?? fps}',
      // 导出段与 trimOriginalVideo 同一套编码参数（码率/编码器跟设置），
      // 预览段维持统一代理编码
      ...(effectiveSpec == null
          ? _encoder()
          : [...effectiveSpec.encodeArgs, '-pix_fmt', 'yuv420p']),
      '-frames:v', '${frameCount(durationMs, atFps: outFps)}',
      out,
    ];
  }

  /// 编码参数。**一律软编 libx264**，不管是导出还是预览。
  ///
  /// 曾经有过一条「向原片规格看齐、用 videotoolbox 硬编」的分支，为的是让
  /// 变速切片和原片规格一致、播放器不必在接缝处重建解码器。它在开发机上成立，
  /// 换一台机器就崩——Intel Mac 的 VideoToolbox 绝大多数编不了 10bit HEVC。
  ///
  /// 代理方案（见 [ProxySpec]）从根上换了思路：预览链路上的每一段都转成**我们
  /// 说了算的同一个规格**，而那个规格是 H.264 8bit，软编就够、且哪台机器上出来
  /// 的都一模一样。于是那条硬编分支连同它的机器相关性一起退休。
  static List<String> _encoder() => const [
        '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20',
        '-profile:v', 'high',
        '-pix_fmt', 'yuv420p',
      ];

  /// 倍率写进滤镜串：去掉浮点尾巴，`PTS/1.5000000000000002` 既难读也没必要
  static String _trim(double v) {
    final text = v.toStringAsFixed(6);
    final trimmed = text.replaceFirst(RegExp(r'0+$'), '');
    return trimmed.endsWith('.') ? trimmed.substring(0, trimmed.length - 1) : trimmed;
  }

  /// 切一段原片的**声音**（画面单独成轨）
  static List<String> trimOriginalAudio({
    required String source,
    required int startMs,
    required int endMs,
    required String out,
    double? atFps,
  }) =>
      [
        '-y', '-v', 'error',
        '-i', source,
        '-ss', _seconds(startMs),
        '-vn',
        // 声音按画面的帧数对齐（不足补静音）：两边各走各的，片尾必然错位
        '-af', 'apad',
        '-t', exactSeconds(endMs - startMs, atFps: atFps).toStringAsFixed(6),
        ..._audioNormalize(),
        out,
      ];

  /// 整体替换的那一段：**把候选素材的声音整段取出来，不裁不补**。
  ///
  /// 整体替换换的是「这一整段」——画面和声音都来自候选，时长随它。裁到原单元
  /// 的长度就不是整体替换了，那是镜头替换该干的事。
  static List<String> wholeReplacementAudio({
    required String input,
    required String out,
  }) =>
      [
        '-y', '-v', 'error',
        '-i', input,
        '-vn',
        ..._audioNormalize(),
        out,
      ];

  /// 把换音色生成的配音套进这个单元的时长：长了裁、短了补静音。
  ///
  /// 合成出来的时长与原句总有几十毫秒出入（TTS 本身就不是确定性的）。不补齐
  /// 的话，后面每一句都会往前挪一点，到片尾口型与画面已经差出半秒。
  static List<String> fitVoiceAudio({
    required String input,
    required int durationMs,
    required String out,
    double? atFps,
  }) =>
      [
        '-y', '-v', 'error',
        '-i', input,
        '-vn',
        '-af', 'apad',
        '-t', exactSeconds(durationMs, atFps: atFps).toStringAsFixed(6),
        ..._audioNormalize(),
        out,
      ];

  /// 按 concat demuxer 的清单把若干段拼起来（同规格，直接 copy，不再重编码）
  static List<String> concat({required String listFile, required String out}) =>
      [
        '-y', '-v', 'error',
        '-f', 'concat', '-safe', '0',
        '-i', listFile,
        '-c', 'copy',
        out,
      ];

  /// concat 清单文件的内容。路径里的单引号要转义，否则清单直接解析失败——
  /// 素材名里出现引号并不罕见。
  static String concatList(Iterable<String> paths) => [
        for (final p in paths) "file '${p.replaceAll("'", r"'\''")}'",
      ].join('\n');

  /// 画面 + 声音合成最终成片
  static List<String> mux({
    required String video,
    required String audio,
    required String out,
  }) =>
      [
        '-y', '-v', 'error',
        '-i', video,
        '-i', audio,
        '-c:v', 'copy',
        '-c:a', 'aac', '-b:a', '128k',
        '-shortest',
        out,
      ];

  /// 把配乐混进人声轨。
  ///
  /// 配乐压到 [bgmVolume]（每段自己的值，见 [BgmSegment.volume]；默认 0.25）：
  /// 垫乐盖过台词是最常见的翻车方式，而这条片子的主体是口播。`duration=first` 让成片长度跟着人声轨走——
  /// 配乐比片子长时不该把片子拖长。
  static List<String> mixBgm({
    required String voice,
    required String bgm,
    required String out,
    required int startMs,
    required int durationMs,
    double bgmVolume = 0.25,
  }) =>
      [
        '-y', '-v', 'error',
        '-i', voice,
        // 配乐从头取，循环铺满这一段（短的循环、长的截断）
        '-stream_loop', '-1', '-i', bgm,
        '-filter_complex',
        '[1:a]volume=$bgmVolume,adelay=$startMs|$startMs,'
            'atrim=0:${_seconds(startMs + durationMs)}[bg];'
            '[0:a][bg]amix=inputs=2:duration=first:dropout_transition=0[a]',
        '-map', '[a]',
        ..._audioNormalize(),
        out,
      ];

  /// 统一画面规格：缩放到目标画幅，比例不同的补黑边（不拉伸变形）。
  /// 给了 [target] 就按原片的分辨率，否则按成片标准的 1080×1920
  static String _scalePad([MediaSpec? target, ExportSpec? spec]) {
    final w = spec?.width ?? target?.width ?? width;
    final h = spec?.height ?? target?.height ?? height;
    return 'scale=$w:$h:force_original_aspect_ratio=decrease,'
        'pad=$w:$h:(ow-iw)/2:(oh-ih)/2:black,setsar=1';
  }

  static List<String> _videoNormalize([ExportSpec? spec]) => [
        '-vf', _scalePad(null, spec),
        '-r', '${spec?.fps ?? fps}',
        ...(spec ?? const ExportSpec()).encodeArgs,
        '-pix_fmt', 'yuv420p',
      ];

  static List<String> _audioNormalize() => [
        '-ar', '$audioSampleRate', '-ac', '2',
        '-c:a', 'pcm_s16le',
      ];

  /// ffmpeg 的时间参数用秒（小数）。毫秒整数除以 1000 保三位小数即可无损。
  static String _seconds(int ms) => (ms / 1000).toStringAsFixed(3);
}
