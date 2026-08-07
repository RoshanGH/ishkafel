import 'dart:io';

import 'package:path/path.dart' as p;

import '../log/app_log.dart';
import 'bgm_library.dart';
import 'bgm_plan.dart';

/// 配乐的本地缓存。
///
/// **签名地址是易腐品**：miaoa 给的 `previewUrl` 带签名，隔天就 403。把它
/// 原样存进任务、之后每次预览和导出都拿去请求，结果是「昨天选好的配乐，
/// 今天预览音轨整条合成失败」——真机上就是这么炸的。
///
/// 所以任务里存的应当只当作「上次拿到的地址」，真要用的时候：
/// 1. 本地已经下过 → 直接用，永不过期，也省掉每次重建预览都重下 2MB
/// 2. 没下过 → 用 id 现取一个新地址再下
/// 3. 取不到新地址 → 退回任务里存的那个（刚选完就用的话它还没坏）
class BgmCache {
  final BgmLibrary library;
  final Directory cacheDir;

  /// 注入下载动作：这一层要能在不联网的情况下测
  final Future<void> Function(String url, File to) download;

  /// 校验缓存里的文件还能不能用（真实实现走 ffprobe）。
  ///
  /// 光看「文件在不在、是不是空的」不够：上一次下到一半、或者存的其实是一段
  /// 403 的 HTML，文件都非空。不验的话要等导出时 ffmpeg 报一个看不懂的错。
  final Future<bool> Function(String path)? verify;

  /// 这次会话里已经验过的，不再重复 ffprobe
  final Set<String> _verified = {};

  /// 自动重试的次数。网络抖一下、或者地址正好在这一刻失效，都不该让用户
  /// 去重选一首曲子——那根本不是他的问题
  final int retries;

  /// 两次重试之间等多久（测试里给 0）
  final Duration retryDelay;

  BgmCache({
    required this.library,
    required this.cacheDir,
    Future<void> Function(String url, File to)? download,
    this.verify,
    this.retries = 2,
    this.retryDelay = const Duration(milliseconds: 400),
  }) : download = download ?? _httpDownload;

  /// 拿到这条配乐的本地路径，必要时下载。
  ///
  /// **失败会自己再试**（[retries] 次）：最常见的两种原因——网络抖动、
  /// 登录/签名过期——重试一次就好了，没道理让用户去重选一首曲子。
  /// 只有「素材已从素材库删除」这种永久错误才立刻放弃。
  Future<String> fetch(BgmMaterial material) async {
    cacheDir.createSync(recursive: true);
    final file = File(p.join(cacheDir.path, '${material.id}.mp3'));
    if (file.existsSync() && file.lengthSync() > 0) {
      if (await _usable(file.path)) return file.path;
      AppLog.warn('缓存里的配乐「${material.name}」解不出来，删掉重下');
      file.deleteSync();
    }

    BgmUnavailableException? last;
    for (var attempt = 0; attempt <= retries; attempt++) {
      if (attempt > 0 && retryDelay > Duration.zero) {
        await Future<void>.delayed(retryDelay);
      }
      try {
        return await _fetchOnce(material, file);
      } on BgmUnavailableException catch (e) {
        last = e;
        if (!e.retryable) rethrow;
        AppLog.warn('配乐「${material.name}」第 ${attempt + 1} 次没取到：${e.message}');
      }
    }
    throw last!;
  }

  Future<String> _fetchOnce(BgmMaterial material, File file) async {
    final url =
        await library.freshPreviewUrl(material.id) ?? material.previewUrl;
    if (url == null || url.isEmpty) {
      // 现取也拿不到、存档里也没有：多半已经从素材库删掉了，再试没意义
      throw BgmUnavailableException(
          '配乐「${material.name}」在素材库里已经找不到了，请重新选一首',
          retryable: false);
    }

    final temp = File('${file.path}.part');
    try {
      await download(url, temp);
      temp.renameSync(file.path);
    } catch (e) {
      // 半截文件会让 ffmpeg 报一个完全看不懂的错，不如直接删掉重来
      if (temp.existsSync()) temp.deleteSync();
      throw BgmUnavailableException(
          '配乐「${material.name}」下载失败（网络不通或登录已过期）：$e');
    }
    if (!await _usable(file.path)) {
      file.deleteSync();
      throw BgmUnavailableException(
          '配乐「${material.name}」下下来的文件解不出来，'
          '多半是地址失效后返回了一个错误页');
    }
    return file.path;
  }

  /// 验一次就记下来：同一次会话里反复用同一首曲子，每次都 ffprobe 是浪费
  Future<bool> _usable(String path) async {
    final check = verify;
    if (check == null) return true;
    if (_verified.contains(path)) return true;
    final ok = await check(path);
    if (ok) _verified.add(path);
    return ok;
  }

  static Future<void> _httpDownload(String url, File to) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
      }
      await response.pipe(to.openWrite());
    } finally {
      client.close(force: true);
    }
  }
}

/// 这条配乐这次拿不到。
///
/// [retryable] 区分「再试一次可能就好了」（网络抖动、登录过期、地址失效后
/// 返回了错误页）和「试多少次都一样」（素材已从素材库删除）。界面据此决定
/// 是给「重试」还是让用户重选。
class BgmUnavailableException implements Exception {
  final String message;
  final bool retryable;
  const BgmUnavailableException(this.message, {this.retryable = true});
  @override
  String toString() => message;
}
