import 'dart:io';

import 'package:path/path.dart' as p;

import '../log/app_log.dart';
import 'miaoa_content_service.dart';
import 'miaoa_tag_service.dart' show MiaoaException;

/// 把候选素材下载到本地，供 ffmpeg 读取。
///
/// **为什么要落地而不是让 ffmpeg 直接吃 URL**：同一条候选会在多条组合里重复
/// 出现，直连等于同一段素材下载好几遍；而且预览地址是有时效的签名 URL，一批
/// 导出跑十几分钟，跑到一半过期就前功尽弃。
///
/// 缓存按素材 id：一次导出里同一条只下一遍，重跑同一批也不必再下。
class MaterialDownloader {
  final MiaoaContentService content;
  final Directory cacheDir;

  /// 注入下载动作：这一层要能在不联网的情况下测
  final Future<void> Function(String url, File to) download;

  MaterialDownloader({
    required this.content,
    required this.cacheDir,
    Future<void> Function(String url, File to)? download,
  }) : download = download ?? _httpDownload;

  Future<String> fetch(int candidateId) async {
    cacheDir.createSync(recursive: true);
    final file = File(p.join(cacheDir.path, '$candidateId.mp4'));
    // 已经下过就直接用。空文件视为上次没下完，重下
    if (file.existsSync() && file.lengthSync() > 0) return file.path;

    final material = await content.fetchById(candidateId);
    final url = material?.previewUrl;
    if (url == null || url.isEmpty) {
      throw MiaoaException('素材 $candidateId 没有可用的下载地址，可能已被删除');
    }
    final temp = File('${file.path}.part');
    try {
      await download(url, temp);
      temp.renameSync(file.path);
    } catch (e) {
      // 半截文件会让 ffmpeg 报一个完全看不懂的错，不如直接删掉重来
      if (temp.existsSync()) temp.deleteSync();
      AppLog.warn('候选素材 $candidateId 下载失败：$e');
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
      client.close();
    }
  }
}
