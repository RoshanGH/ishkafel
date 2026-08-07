import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/log/app_log.dart';
import '../../core/miaoa/miaoa_content_service.dart';
import '../../core/replacement/picked_material.dart';

/// 下载一段字节。注入而不是内建，测试里不碰网络。
typedef BytesFetcher = Future<List<int>> Function(String url);

/// 把「挑中的素材」落到盘上。
///
/// 只落信息与首帧图，不落视频本体：一个单元可以挑好几条、一条几十兆，
/// 而真正需要视频是在预览合成与导出的时候，那两处本来就按 id 现取。
///
/// **为什么首帧图要下载而不是存地址**：素材库给的是签名 URL，一天就过期。
/// 存 URL 等于存一张迟早打不开的图——配乐那边已经因为这件事踩过一次坑
/// （见 `bgm_cache.dart`）。
class PickedMaterialStore {
  /// 首帧图存哪儿
  final Directory dir;
  final BytesFetcher fetch;

  PickedMaterialStore({required this.dir, required this.fetch});

  /// 把一条候选转成可落地的记录。
  ///
  /// 图下不下得来都返回记录——名字和台词才是用户核对「是不是我选的那三条」
  /// 的依据，为一张缩略图把整条记录丢掉才是本末倒置。
  Future<PickedMaterial> save(
    CandidateMaterial material, {
    int? durationMs,
  }) async {
    final record = PickedMaterial(
      id: material.id,
      name: material.name,
      voiceover: material.voiceover,
      sceneDescription: material.sceneDescription,
      durationMs: durationMs,
    );
    return record.withThumb(await _thumb(material));
  }

  Future<String?> _thumb(CandidateMaterial material) async {
    final url = material.thumbnailUrl;
    if (url == null || url.isEmpty) return null;
    final file = File(p.join(dir.path, '${material.id}.jpg'));
    // 已经下过就不再下：同一条素材可能被好几个单元选中
    if (file.existsSync() && file.lengthSync() > 0) return file.path;
    try {
      final bytes = await fetch(url);
      if (bytes.isEmpty) return null;
      dir.createSync(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (e) {
      AppLog.warn('已选素材 ${material.id} 的首帧图下载失败：$e');
      return null;
    }
  }

  /// 清掉不再被引用的首帧图。取消勾选之后那张图就没人看了，留着只是占地方。
  void prune(Set<int> keepIds) {
    if (!dir.existsSync()) return;
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      final id = int.tryParse(p.basenameWithoutExtension(entity.path));
      if (id == null || keepIds.contains(id)) continue;
      try {
        entity.deleteSync();
      } catch (e) {
        // 删不掉不是错误，下次再说
        AppLog.warn('清理已选素材首帧图失败：$e');
      }
    }
  }
}
