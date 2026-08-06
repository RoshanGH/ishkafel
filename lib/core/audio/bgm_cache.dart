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

  BgmCache({
    required this.library,
    required this.cacheDir,
    Future<void> Function(String url, File to)? download,
  }) : download = download ?? _httpDownload;

  /// 拿到这条配乐的本地路径，必要时下载。
  Future<String> fetch(BgmMaterial material) async {
    cacheDir.createSync(recursive: true);
    final file = File(p.join(cacheDir.path, '${material.id}.mp3'));
    // 空文件视为上次没下完，重下
    if (file.existsSync() && file.lengthSync() > 0) return file.path;

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
    } catch (e) {
      // 半截文件会让 ffmpeg 报一个完全看不懂的错，不如直接删掉重来
      if (temp.existsSync()) temp.deleteSync();
      AppLog.warn('配乐「${material.name}」(${material.id}) 下载失败：$e');
      rethrow;
    }
    return file.path;
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
