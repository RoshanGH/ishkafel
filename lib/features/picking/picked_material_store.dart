import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/ai/frame_check.dart';
import '../../core/log/app_log.dart';
import '../../core/miaoa/miaoa_content_service.dart';
import '../../core/replacement/picked_material.dart';
import '../../core/replacement/picked_thumbs.dart';

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

  /// 顺手对首帧图做一次画面自查（烧字 + 产品露出品牌）。
  /// 没配就记「没查过」——不冒充「画面没问题」。
  final FrameChecker? frameChecker;

  PickedMaterialStore({
    required this.dir,
    required this.fetch,
    this.frameChecker,
  });

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
    final withThumb = record.withThumb(await _thumb(material));
    return _checkFrame(withThumb);
  }

  /// 首帧图已经在本地了，顺手问一句「画面上烧字了吗、露的是谁家产品」——
  /// 不额外下视频、不额外抽帧，只对**挑中的**那几条跑，不是对整页检索结果。
  /// 两件事一次调用问完：多问一个问题几乎不加钱，多跑一次调用是成倍的。
  ///
  /// **这里只有一帧，看得不全**：产品可能只在素材的某几秒里出现（真机：
  /// 素材 114801 首帧是滴露瓶、中段是微波炉内部）。挑素材这一刻素材本体
  /// 还没下载，抽不了多帧——所以结论标成「看过 1 帧」，等提交方案时素材
  /// 已经在本地，那边会拿头中尾三帧再看一次顶掉它
  /// （见 `plan_submission.dart` 的 `_checked`）。
  ///
  /// 看不成就保持「没查过」（[PickedMaterial.burnedText] 为 null）。
  /// 把看不成当成「画面没问题」，就是把一条会毁掉整片的素材静默放行。
  Future<PickedMaterial> _checkFrame(PickedMaterial record) async {
    final checker = frameChecker;
    final path = record.thumbPath;
    if (checker == null || path == null) return record;
    try {
      return record.withFrameCheck(await checker.check([path]));
    } catch (e) {
      AppLog.warn('已选素材 ${record.id} 的画面没看成（$e）——'
          '这条素材会标成「未检查」，不会当成画面没问题');
      return record;
    }
  }

  /// 首帧图交给 [PickedThumbs]——**界面和 Agent 两条路共用那一份**。
  ///
  /// 以前这段只长在界面这条路上，Agent 提交方案那条一张都不下，于是纯 Agent
  /// 挑的素材进了审核页全是「画面还没抽出来」（2026-09-18 真机）。
  Future<String?> _thumb(CandidateMaterial material) =>
      PickedThumbs(dir: dir, fetch: fetch).ensure(material);

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
