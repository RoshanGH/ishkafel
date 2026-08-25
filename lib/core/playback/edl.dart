import '../log/app_log.dart';
import 'track_plan.dart';

/// 把一条轨拼成 libmpv 的 `edl://` 地址。
///
/// EDL 是 mpv 内置的「虚拟文件」协议：把若干个源文件的若干区间描述成一条
/// 连续的流，播放器当成一个普通文件打开，**不转码、不落任何中间文件**。
/// 真机实测（媒体是本机素材）：
///
/// ```
/// edl://候选.mp4,start=0.0,length=11.3;原片.mp4,start=15.09,length=15.0
/// → 打开成功，时长 26300ms（正好 11.3+15.0），3 条轨道，正常播
/// ```
///
/// **变速不在这里做**：EDL 没有逐段倍速。需要变速的段落（镜头替换要把候选
/// 塞进原坑位）由调用方预先渲染成一个时长已经对齐的切片，到这里时它的
/// 时长就等于坑位时长，倍速恒为 1。
class Edl {
  /// 转义规则：mpv 用 `%<字节数>%<原文>` 表示「接下来这么多字节原样读」，
  /// 路径里有逗号、分号、百分号时必须这么写，否则会被当成分隔符。
  /// 中文路径是多字节的，长度要按 **UTF-8 字节数** 算，不是字符数。
  static String quote(String raw) {
    final bytes = _utf8Length(raw);
    return '%$bytes%$raw';
  }

  static int _utf8Length(String s) {
    var n = 0;
    for (final rune in s.runes) {
      if (rune <= 0x7F) {
        n += 1;
      } else if (rune <= 0x7FF) {
        n += 2;
      } else if (rune <= 0xFFFF) {
        n += 3;
      } else {
        n += 4;
      }
    }
    return n;
  }

  /// 空轨返回 null——没有东西可播时不该造一个空 EDL 塞给播放器
  static String? of(List<TrackSegment> segments) {
    if (segments.isEmpty) return null;
    _warnIfHoles(segments);
    final parts = [
      for (final s in segments)
        '${quote(s.source)},start=${_seconds(s.inMs)},'
            'length=${_seconds(s.durationMs)}',
    ];
    return 'edl://${parts.join(';')}';
  }

  /// 毫秒转秒。保留三位小数——EDL 的时间是浮点秒，写成整数会丢帧
  static String _seconds(int ms) => (ms / 1000).toStringAsFixed(3);

  /// 段与段之间留了洞就叫出来。
  ///
  /// **EDL 没有「空档」这个概念**：它把各段首尾相接成一条流，洞会被直接
  /// 压掉，从那儿起后面所有内容都提前一截。画面轨提前 = 画面与声音对不上；
  /// 声音轨提前 = 累到片尾声音先播完，跟随轨被反复拽回末尾，听起来是
  /// 「最后几个字一直重复」（真机反馈，排查了两轮才定位到）。
  ///
  /// 这类错位在界面上没有任何征兆，只能靠日志指认——所以宁可多打一行。
  static void _warnIfHoles(List<TrackSegment> segments) {
    var at = segments.first.atMs;
    for (final s in segments) {
      if (s.atMs != at) {
        AppLog.warn('EDL 轨上有洞：期望 ${at}ms 接上，实际从 ${s.atMs}ms 开始'
            '（差 ${s.atMs - at}ms，源 ${s.source}）——'
            'EDL 会把洞压掉，这一段之后的内容都会提前');
        return;
      }
      at += s.durationMs;
    }
  }
}
