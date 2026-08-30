import '../ai/frame_check.dart';
import '../log/app_log.dart';
import 'script_doc.dart';

/// 给脚本成片挑中的素材做画面自查（烧字 + 产品露出品牌）。
///
/// **为什么这条线也要查**：两条线都要给台词烧一行字幕。素材画面上本来就
/// 烧着别家的字，叠上去就是两层字、内容还毫不相干——片子直接废，
/// 两条线一样废。而素材库给的画面描述里一个字都看不出来。
///
/// 品牌错位在这边甚至更难发现：没有原片，就没有「本片是什么牌子」的现成
/// 参照，只能靠挑中的素材之间互相比。
///
/// 单独一个入口，是因为编导台有好几处在造 [LineShot]（自动铺一版、
/// 手动挑、划词建镜、命令行提交）。**每处各写一份的话，迟早只有一份是
/// 对的**——取段在这个项目里就是这么栽了三次（改了导出、忘了剪映、
/// 忘了预览）。
Future<List<LineShot>> checkedShots({
  required List<LineShot> shots,
  required Future<FrameCheck> Function(LineShot shot) check,
}) async {
  // 同一条素材可能配给好几句台词：查一次，结果共享。查三次是白花三份钱
  final done = <int, FrameCheck>{};
  final out = <LineShot>[];
  for (final shot in shots) {
    if (!_needsCheck(shot)) {
      out.add(shot);
      continue;
    }
    final hit = done[shot.materialId];
    if (hit != null) {
      out.add(_applied(shot, hit));
      continue;
    }
    try {
      final result = await check(shot);
      done[shot.materialId] = result;
      out.add(_applied(shot, result));
    } catch (e) {
      // 看不成就保持「没查过」——**绝不冒充「画面没问题」**，
      // 那等于把一条会毁掉整片的素材静默放行
      AppLog.warn('素材 ${shot.materialId} 的画面没看成（$e）——'
          '这一镜会标成「未检查」，不会当成画面没问题');
      out.add(shot);
    }
  }
  return List.unmodifiable(out);
}

/// 要不要查这一镜。
///
/// - **本地源不查**：那是从参考片里截的一段，画面就是原片自己的。
///   报「烧着字」只会天天误报，人很快就不看警告了
/// - **看全了（3 帧）不查**：一条素材看一次就够
/// - **只看过一帧的要补查**：一帧漏报产品露出（真机：素材 114801 首帧是
///   一排滴露瓶、中段是微波炉内部）
bool _needsCheck(LineShot shot) =>
    shot.localSource == null && (shot.framesSeen ?? 0) < 3;

LineShot _applied(LineShot shot, FrameCheck check) => LineShot(
      materialId: shot.materialId,
      name: shot.name,
      voiceover: shot.voiceover,
      sceneDescription: shot.sceneDescription,
      thumbnailUrl: shot.thumbnailUrl,
      fileKey: shot.fileKey,
      durationMs: shot.durationMs,
      burnedText: List.unmodifiable(check.burnedText),
      productBrand: check.productBrand,
      framesSeen: check.framesSeen,
      trimStartMs: shot.trimStartMs,
      speed: shot.speed,
      allocMs: shot.allocMs,
      localSource: shot.localSource,
      sourceVolume: shot.sourceVolume,
      startWord: shot.startWord,
      endWord: shot.endWord,
      legacySubtitleText: shot.legacySubtitleText,
    );

/// 「看一条素材的画面」的签名：给素材 id 和时长，回一份自查结果。
///
/// 用 id 而不是整个 [LineShot]：真正要用的只有这两样，而这样一来
/// 编导台和命令行两头可以共用同一个实现。
typedef ShotFrameCheck = Future<FrameCheck> Function(int materialId,
    int? durationMs);


/// 哪些镜头该做画面自查了：**还没看全、而且素材已经落到本地**。
///
/// 挑素材那一刻素材本体还没下载（只有一条签名地址），看不了。但「挑中即
/// 下载」——进入方案的都要钉死到本地，落地之后就能抽帧了。时长回填走的
/// 就是这个时机（「文件都在本地了，量一下几十毫秒的事，没有必要继续猜」），
/// 画面自查是同一类事：**能看清的时候就该看**，而不是让人拿到成片才发现
/// 素材上烧着别家的字。
///
/// 同一条素材配给好几句台词时只列一次——查两次是白花两份钱。
List<LineShot> shotsNeedingFrameCheck({
  required ScriptDoc doc,
  required String? Function(int materialId) localPathOf,
}) {
  final seen = <int>{};
  final out = <LineShot>[];
  for (final line in doc.lines) {
    for (final shot in line.shots) {
      if (!_needsCheck(shot)) continue;
      if (!seen.add(shot.materialId)) continue;
      if (localPathOf(shot.materialId) == null) continue;
      out.add(shot);
    }
  }
  return List.unmodifiable(out);
}
