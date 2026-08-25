import '../ffmpeg/rendered_cache.dart';

/// 把进**预览口播轨**的每一段音频规范成同一个规格。
///
/// 口播轨是把几十段音频拼成一条流播放的，而这条轨上的来源本来五花八门：
/// 配音是语音合成出来的 mp3（实测 24kHz 单声道），画面行用的是素材自己的
/// 声音（mp4 里的 aac，多为 48kHz 立体声），配音比画面短时还要垫一段静音。
/// **规格一变，播放器就要停下来重新搭一遍音频链路**——画面轨上同样的接缝
/// 已经让主时钟卡死过（真机：卡在 9955ms 不动，一个词反复念十几遍）。
///
/// 所以进这条轨之前统一转成 48kHz 立体声（与导出同规格），并**补足到坑位
/// 那么长**：短了垫静音、长了截断。这样口播轨上每一段都长得一样，接缝
/// 不复存在，也不再需要单独的静音垫文件。
///
/// 按内容指纹缓存：同一段音频只转一次，反复进出预览不重跑 ffmpeg。
class PreviewVoiceNormalizer {
  final RenderedCache cache;

  PreviewVoiceNormalizer({required this.cache});

  /// 统一后的采样率与声道数——与导出一致，成片与预览听到的是同一种声音
  static const sampleRate = 48000;
  static const channels = 2;

  /// 规范一段音频。
  ///
  /// [inMs] 从源的哪一刻开始取（画面行按镜头取段；配音从头取）。
  /// [durationMs] 这一段在成片时间轴上占多长——**输出严格就是这么长**，
  /// 源不够就在尾巴上垫静音。
  /// [speed] 画面行的镜头可能变速，声音要跟着变（与导出的 atempo 同一套）。
  Future<String> normalize({
    required String source,
    required int inMs,
    required int durationMs,
    double speed = 1.0,
    String tag = 'seg',
  }) {
    final seconds = (durationMs / 1000).toStringAsFixed(3);
    // 变速时要多取一点源：1.5 倍速下出 2 秒声音得取 3 秒
    final takeSeconds = (durationMs * speed / 1000).toStringAsFixed(3);
    final filters = [
      if ((speed - 1).abs() > 1e-6) 'atempo=$speed',
      'aresample=$sampleRate',
      // apad 先把尾巴垫够，再由输出侧的 -t 截到精确长度
      'apad',
    ].join(',');
    return cache.render(
      key: 'voice1|$source|$inMs|$durationMs|$speed',
      prefix: 'pv_$tag',
      extension: 'mp3',
      what: '预览口播段（$tag）',
      args: (out) => [
        '-y', '-loglevel', 'error',
        '-ss', (inMs / 1000).toStringAsFixed(3),
        '-t', takeSeconds,
        '-i', source,
        '-vn',
        '-af', filters,
        '-t', seconds,
        '-ar', '$sampleRate',
        '-ac', '$channels',
        '-c:a', 'libmp3lame', '-b:a', '128k',
        out,
      ],
    );
  }

  /// 源里根本没有音轨时用的纯静音段（画面行的素材可能是无声的）
  Future<String> silence({required int durationMs, String tag = 'mute'}) {
    final seconds = (durationMs / 1000).toStringAsFixed(3);
    return cache.render(
      key: 'silence1|$durationMs',
      prefix: 'pv_$tag',
      extension: 'mp3',
      what: '预览静音段（$durationMs ms）',
      args: (out) => [
        '-y', '-loglevel', 'error',
        '-f', 'lavfi',
        '-i', 'anullsrc=r=$sampleRate:cl=stereo',
        '-t', seconds,
        '-c:a', 'libmp3lame', '-b:a', '128k',
        out,
      ],
    );
  }
}
