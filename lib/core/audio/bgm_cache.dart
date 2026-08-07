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

  BgmCache({
    required this.library,
    required this.cacheDir,
    Future<void> Function(String url, File to)? download,
    this.verify,
  }) : download = download ?? _httpDownload;

  /// 拿到这条配乐的本地路径，必要时下载。
  Future<String> fetch(BgmMaterial material) async {
    cacheDir.createSync(recursive: true);
    final file = File(p.join(cacheDir.path, '${material.id}.mp3'));
    // 空文件视为上次没下完，重下
    if (file.existsSync() && file.lengthSync() > 0) {
      if (await _usable(file.path)) return file.path;
      AppLog.warn('缓存里的配乐「${material.name}」解不出来，删掉重下');
      file.deleteSync();
    }

    final url =
        await library.freshPreviewUrl(material.id) ?? material.previewUrl;
    if (url == null || url.isEmpty) {
      throw BgmUnavailableException(
          '配乐「${material.name}」没有可用的下载地址，可能已从素材库删除');
    }

    final temp = File('${file.path}.part');
    try {
      await download(url, temp);
      temp.renameSync(file.path);
      // 重下之后还是坏的就别往下传了——交出去只会让 ffmpeg 报一个看不懂的错
      if (!await _usable(file.path)) {
        file.deleteSync();
        throw BgmUnavailableException(
            '配乐「${material.name}」下下来是坏的（可能是地址失效后返回的错误页），'
            '请重新选一次这一段的配乐');
      }
    } on BgmUnavailableException {
      rethrow;
    } catch (e) {
      // 半截文件会让 ffmpeg 报一个完全看不懂的错，不如直接删掉重来
      if (temp.existsSync()) temp.deleteSync();
      AppLog.warn('配乐「${material.name}」(${material.id}) 下载失败：$e');
      rethrow;
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

/// 这条配乐这次拿不到。**只影响它自己那一段**，不该让整条音轨作废
class BgmUnavailableException implements Exception {
  final String message;
  const BgmUnavailableException(this.message);
  @override
  String toString() => message;
}
