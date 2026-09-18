import 'dart:io';

import 'package:path/path.dart' as p;

import '../log/app_log.dart';
import '../miaoa/miaoa_content_service.dart';

/// 已选素材的首帧图：落到哪儿、什么时候下、什么时候算已经有了。
///
/// **两条路共用这一份**——界面挑素材（`PickedMaterialStore`）和 Agent 提交
/// 方案（`cli/plan_submission.dart`）都要这张图。
///
/// 2026-09-18 真机：Agent 挑完之后人进审核页，整屏候选卡全是「画面还没抽
/// 出来」，鼠标放上去却能播。原因是下载首帧图的代码只长在界面那条路上，
/// Agent 那条路只从已有记录里捡 `thumbPath`，捡不到就一直是 null。
///
/// 这和同一处已经修过的两条是同一个形状（素材时长、画面自查——都是「界面
/// 挑素材时会做、Agent 这条路上不做」）。后果落在人身上：审核页正是「Agent
/// 挑完、人来把关」的地方，而它的全部意义就是**看图判断**。看不到图，
/// 这一步等于废了，而且 Agent 用得越多越常见。
class PickedThumbs {
  /// 落点：`picked_thumbs/<任务 id>/`
  final Directory dir;

  /// 取字节（注入点：测试零网络）
  final Future<List<int>> Function(String url) fetch;

  const PickedThumbs({required this.dir, required this.fetch});

  String pathOf(int materialId) => p.join(dir.path, '$materialId.jpg');

  /// 本地已经有这张图吗。
  ///
  /// **按内容非空判，不是按文件名存在判**——上一次没下完留下的空壳会一直
  /// 被当成命中端出来，而界面只看路径存不存在，于是画出来是一整块纯色底、
  /// 一个字都不说（`ThumbImage` 解不出来时什么都不画）。
  String? cached(int materialId) {
    final f = File(pathOf(materialId));
    return f.existsSync() && f.lengthSync() > 0 ? f.path : null;
  }

  /// 确保这条素材的首帧图在本地，返回路径；拿不到返回 null。
  ///
  /// 拿不到就**如实留空**，不写一个空文件顶上——界面会照实说「画面还没抽
  /// 出来」，那比端出一张解不开的图强。
  Future<String?> ensure(CandidateMaterial material) async {
    final hit = cached(material.id);
    if (hit != null) return hit;

    final url = material.thumbnailUrl;
    if (url == null || url.isEmpty) return null;
    try {
      final bytes = await fetch(url);
      // 空响应不写：写了就是留下一个存在但解不出来的文件
      if (bytes.isEmpty) return null;
      dir.createSync(recursive: true);
      final out = File(pathOf(material.id));
      await out.writeAsBytes(bytes, flush: true);
      return out.path;
    } catch (e) {
      AppLog.warn('已选素材 ${material.id} 的首帧图下载失败：$e');
      return null;
    }
  }
}
