import 'dart:io';

import '../log/app_log.dart';

/// 探测某个绝对路径上是否存在可执行文件（注入点，便于单测零真实依赖）
typedef ExecutableProbe = bool Function(String absolutePath);

/// 在当前 PATH 中查找可执行文件，返回绝对路径；找不到返回 null
typedef PathLookup = String? Function(String executableName);

/// ffmpeg/ffprobe 环境探测结果（不可变）
class MediaToolsStatus {
  final String? ffmpegPath;
  final String? ffprobePath;

  const MediaToolsStatus({this.ffmpegPath, this.ffprobePath});

  bool get isReady => ffmpegPath != null && ffprobePath != null;

  /// 缺失的工具名，顺序固定为 ffmpeg、ffprobe，便于稳定展示
  List<String> get missingTools => List.unmodifiable([
        if (ffmpegPath == null) MediaToolsLocator.ffmpeg,
        if (ffprobePath == null) MediaToolsLocator.ffprobe,
      ]);
}

/// ffmpeg/ffprobe 可执行文件定位。
///
/// 为什么需要：macOS 上由 Finder / `open` 启动的 GUI 进程继承的是 launchd 的
/// 环境，本机实测 `launchctl getenv PATH` 为空，于是进程只拿到系统默认
/// `/usr/bin:/bin:/usr/sbin:/sbin`——不含 Homebrew 的 `/opt/homebrew/bin`
/// 与 `/usr/local/bin`。裸名调用 `Process.start('ffmpeg', ...)` 必然
/// ENOENT，而终端里 `flutter run` 因为继承了 shell 的完整 PATH 所以从未暴露。
///
/// 解析顺序：常见安装目录（Apple Silicon Homebrew → Intel Homebrew）→ 当前
/// PATH（`which`）。结果（含未命中）一次性缓存，避免每次起子进程都做磁盘探测。
class MediaToolsLocator {
  static const String ffmpeg = 'ffmpeg';
  static const String ffprobe = 'ffprobe';

  /// Homebrew 在 Apple Silicon / Intel 上的默认安装目录
  static const List<String> defaultSearchDirs = [
    '/opt/homebrew/bin',
    '/usr/local/bin',
  ];

  final List<String> searchDirs;
  final ExecutableProbe probe;
  final PathLookup lookupOnPath;

  /// 解析缓存：值为 null 表示「已探测过且没找到」，同样不再重复探测
  final Map<String, String?> _cache = {};

  MediaToolsLocator({
    List<String>? searchDirs,
    ExecutableProbe? probe,
    PathLookup? lookupOnPath,
  })  : searchDirs = List.unmodifiable(searchDirs ?? defaultSearchDirs),
        probe = probe ?? _fileExists,
        lookupOnPath = lookupOnPath ?? _whichOnPath;

  /// 解析可执行文件的绝对路径；找不到返回 null（由调用方决定如何提示用户）
  String? resolve(String executableName) =>
      _cache.putIfAbsent(executableName, () => _resolveUncached(executableName));

  /// 清掉「没找到」的缓存，让下一次解析重新探测。
  ///
  /// 缓存本身是必要的（否则每起一次子进程都做磁盘探测），但**未命中**的结果
  /// 不能永久缓存：用户按横幅提示装好 ffmpeg 后，不清缓存就必须重启 app 才能
  /// 恢复功能。已命中的结果保留——路径不会凭空变化，重探是白花开销。
  void forgetMisses() => _cache.removeWhere((_, path) => path == null);

  String? _resolveUncached(String executableName) {
    for (final dir in searchDirs) {
      final candidate = '$dir/$executableName';
      if (probe(candidate)) return candidate;
    }
    return lookupOnPath(executableName);
  }

  /// 启动期预检：一次性解析 ffmpeg 与 ffprobe，供 UI 常驻展示环境状态
  MediaToolsStatus preflight() {
    final status = MediaToolsStatus(
      ffmpegPath: resolve(ffmpeg),
      ffprobePath: resolve(ffprobe),
    );
    if (!status.isReady) {
      AppLog.warn('未检测到 ${status.missingTools.join('、')}，视频处理功能不可用');
    }
    return status;
  }

  static bool _fileExists(String absolutePath) =>
      File(absolutePath).existsSync();

  /// 用绝对路径调用 `/usr/bin/which`（该目录在任何启动方式下都在 PATH 中）；
  /// which 自身异常（如系统裁剪）一律视为未找到，不向上抛。
  static String? _whichOnPath(String executableName) {
    try {
      final result = Process.runSync('/usr/bin/which', [executableName]);
      if (result.exitCode != 0) return null;
      final path = (result.stdout as String).trim();
      return path.isEmpty ? null : path;
    } catch (e) {
      AppLog.warn('PATH 查找 $executableName 失败：$e');
      return null;
    }
  }
}
