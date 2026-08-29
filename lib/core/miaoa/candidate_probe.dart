import '../ffmpeg/process_runner.dart';
import '../log/app_log.dart';

/// 候选素材的时长与分辨率
class CandidateSpec {
  final int durationMs;
  final int width;
  final int height;

  const CandidateSpec({
    required this.durationMs,
    required this.width,
    required this.height,
  });
}

/// 候选素材规格探测器。
///
/// **为什么需要它**：miaoa 分镜库的检索与详情接口都不返回 `duration` 与
/// `resolution`（真机 20/20 样本实测均为 null），而产品已定的两条策略都依赖
/// 它们——「时长对齐 ±15% 容忍度」要算时长差徽标、「分辨率适配」要标低清
/// 徽标。因此改为用 ffprobe 直接读候选的签名预览 URL 探测（实测可行，
/// 单条约 3 秒，只读文件头不下载整片）。
///
/// 结果按素材 id 缓存：同一个候选在翻页、切换检索模式、来回选中之间会被
/// 反复看到，重复探测既慢又浪费带宽。
class CandidateProbe {
  final ProcessRunner run;
  final String ffprobeBinary;

  CandidateProbe({
    this.run = systemProcessRunner,
    this.ffprobeBinary = 'ffprobe',
  });

  final _cache = <int, CandidateSpec>{};

  /// 已探测过的条数（供上层展示进度）
  int get cachedCount => _cache.length;

  /// 取缓存结果；未探测过返回 null（上层据此显示「探测中」占位）
  CandidateSpec? cached(int materialId) => _cache[materialId];

  /// 探测一条候选。失败返回 null（候选卡退化为不显示时长差，不阻断选材）。
  ///
  /// 这里刻意不抛异常：候选面板一次要展示二十条，任何一条探测失败都不该
  /// 让整个面板报错——用户仍然可以凭画面与标签挑选。
  Future<CandidateSpec?> probe({
    required int materialId,
    required String? previewUrl,

    /// 这条素材在本地的路径。**有就读本地**：一条素材联网量要一秒，
    /// 一百多条就是一百多秒，而读本地文件只要 0.15 秒。网络那条路还会失败
    /// （地址过期、网断），而量不到时长会让取段退回快进
    String? localPath,
  }) async {
    final hit = _cache[materialId];
    if (hit != null) return hit;
    final source = (localPath != null && localPath.isNotEmpty)
        ? localPath
        : previewUrl;
    if (source == null || source.isEmpty) return null;

    try {
      final result = await run(ffprobeBinary, [
        '-v',
        'error',
        '-select_streams',
        'v:0',
        '-show_entries',
        'stream=width,height',
        '-show_entries',
        'format=duration',
        '-of',
        'default=nw=1',
        source,
      ]);
      if (result.exitCode != 0) {
        AppLog.warn('候选素材规格探测失败（id=$materialId，exit=${result.exitCode}）');
        return null;
      }
      final spec = parseFfprobeOutput(_text(result.stdout));
      if (spec != null) _cache[materialId] = spec;
      return spec;
    } catch (e) {
      AppLog.warn('候选素材规格探测异常（id=$materialId）：$e');
      return null;
    }
  }

  static String _text(Object? out) => out is String ? out : '';

  /// 解析 `-of default=nw=1` 的键值输出。字段缺失或非法一律返回 null，
  /// 不要用 0 冒充——0 会一路流到时长差计算里变成「差 100%」的假徽标。
  static CandidateSpec? parseFfprobeOutput(String stdout) {
    int? width;
    int? height;
    double? durationSec;
    for (final line in stdout.split('\n')) {
      final idx = line.indexOf('=');
      if (idx <= 0) continue;
      final key = line.substring(0, idx).trim();
      final value = line.substring(idx + 1).trim();
      switch (key) {
        case 'width':
          width = int.tryParse(value);
        case 'height':
          height = int.tryParse(value);
        case 'duration':
          durationSec = double.tryParse(value);
      }
    }
    if (width == null || height == null || durationSec == null) return null;
    if (width <= 0 || height <= 0 || durationSec <= 0) return null;
    return CandidateSpec(
      durationMs: (durationSec * 1000).round(),
      width: width,
      height: height,
    );
  }
}

/// 候选素材相对目标片段的时长匹配程度（产品已定：±15% 容忍度混合策略）
enum DurationFit {
  /// 在容忍度内：变速即可对齐
  within,

  /// 超出容忍度且候选更长：变速到上限后裁尾保头
  tooLong,

  /// 超出容忍度且候选更短：慢放 + 末帧定格兜底，列表里排后并标警告
  tooShort,
}

/// 判定候选时长与目标片段时长的匹配程度。
///
/// [tolerance] 默认 0.15，对应「±15%（设置可调）」这条已定决策。
DurationFit judgeDurationFit({
  required int candidateMs,
  required int targetMs,
  double tolerance = 0.15,
}) {
  if (targetMs <= 0) return DurationFit.within;
  final ratio = (candidateMs - targetMs) / targetMs;
  if (ratio.abs() <= tolerance) return DurationFit.within;
  return ratio > 0 ? DurationFit.tooLong : DurationFit.tooShort;
}
