import 'dart:io';

import '../log/app_log.dart';
import 'media_spec.dart';
import 'process_runner.dart';
import 'proxy_spec.dart';
import 'rendered_cache.dart';

/// 把一个视频转成**预览代理**（见 [ProxySpec]）。原片与候选素材共用这一条路。
///
/// ## 为什么要有它
///
/// 预览是把「原片一段 + 候选素材一段 + 变速切片一段」拼成一条 EDL 交给
/// 播放器。**段与段规格不一致，播放器就要在接缝处重建解码器**——轻则画面停
/// 一拍，重则丢帧狂追（真机上量到过从替换点起 1.67× 连跑 6.5 秒，见
/// `docs/2026-08-10-预览接缝：变速镜头为什么会加速播放.md`）。
///
/// 此前的做法是把每条素材转成**原片的规格**。它在开发机上成立，换一台机器
/// 就崩：Intel Mac 的 VideoToolbox 绝大多数编不了 10bit HEVC，而原片是什么
/// 规格不受我们控制。所以改成——**都转成我们说了算的同一个规格**。
///
/// ## 边界
///
/// > 代理只用于预览。导出一律走原始素材。
///
/// 见 `test/core/export/export_uses_original_test.dart`。
///
/// ## 时长必须严丝合缝
///
/// EDL 里每一段都写着 `start=X,length=Y`，这些数字是按**原片时间轴**算的。
/// 代理要是比原片长了短了，后面每一段的取材位置就全错。所以转完必检时长，
/// 对不上就**退回原文件**——宁可留着那一下接缝顿挫，也不能让画面与台词错位。
class ProxyBuilder {
  final RenderedCache cache;
  final ProcessRunner run;

  /// 时长差多少算不可接受。一帧上下是编码器凑整的正常误差；
  /// 超过 100ms 就意味着源文件是可变帧率之类的情况，强转 CFR 改变了时长
  static const int toleranceMs = 100;

  ProxyBuilder({required this.cache, required this.run});

  /// 返回可直接播的本地路径。
  ///
  /// [frameRate] 是**原片的**帧率（`30/1` 或 `29.97` 都认）——代理跟着它走，
  /// 否则时间线上每一帧的位置都要重算，而本产品所有切分边界都按帧对齐。
  ///
  /// 转不动、或转出来时长对不上，都退回 [path] 本身并留下告警。
  Future<String> build({required String path, required String frameRate}) async {
    final spec = await probe(path);
    if (ProxySpec.matches(spec)) return path; // 已经是代理规格，一个字节都不用动

    final sourceMs = await _durationMs(path);
    try {
      final out = await cache.render(
        key: 'proxy|$path|$frameRate|${ProxySpec.width}x${ProxySpec.height}',
        prefix: 'proxy',
        extension: 'mp4',
        args: (dest) => ProxySpec.encodeArgs(
            input: path, frameRate: frameRate, out: dest),
        what: '生成预览代理',
      );
      if (await _durationMatches(sourceMs, out)) return out;
      return path;
    } catch (e) {
      AppLog.warn('生成预览代理失败，先按原样用（接缝处可能有一下顿挫）：$e');
      return path;
    }
  }

  /// 代理与原片的时长对得上吗。对不上就不能用——EDL 的取材位置会整体错位
  Future<bool> _durationMatches(int? sourceMs, String proxyPath) async {
    if (sourceMs == null) return true; // 原片时长都读不出来，无从比对
    final proxyMs = await _durationMs(proxyPath);
    if (proxyMs == null) return true;
    final drift = (proxyMs - sourceMs).abs();
    if (drift <= toleranceMs) return true;
    AppLog.warn('预览代理时长对不上（差 ${drift}ms），退回原文件——'
        '错位的画面比一下顿挫严重得多');
    return false;
  }

  Future<MediaSpec?> probe(String path) async {
    if (!File(path).existsSync()) return null;
    try {
      final result = await run('ffprobe', MediaSpec.probeArgs(path));
      if (result.exitCode != 0) return null;
      return MediaSpec.tryParse('${result.stdout}');
    } catch (e) {
      AppLog.warn('读不出媒体规格（$path）：$e');
      return null;
    }
  }

  Future<int?> _durationMs(String path) async {
    try {
      final result = await run('ffprobe', [
        '-v', 'error',
        '-show_entries', 'format=duration',
        '-of', 'default=nw=1:nk=1',
        path,
      ]);
      if (result.exitCode != 0) return null;
      final seconds = double.tryParse('${result.stdout}'.trim());
      return seconds == null ? null : (seconds * 1000).round();
    } catch (_) {
      return null;
    }
  }
}

/// ffmpeg 的 `-r` 要一个能解析的帧率串。`videoInfo.fps` 是 double，
/// 29.97 这种直接写成小数即可；整数不带小数点更好读
String frameRateArg(double fps) {
  if (fps <= 0) return '30';
  if (fps == fps.roundToDouble()) return '${fps.round()}';
  return fps.toStringAsFixed(3);
}
