import 'package:meta/meta.dart';

import '../ai/frame_check.dart';
import '../log/app_log.dart';

/// 已经挑中的素材，**落到盘上的那一份**。
///
/// 为什么要落地而不是每次现拉：勾选状态原本只画在候选卡上，而候选卡只有
/// 当前这一页的检索结果。翻一页、换个检索方式、换个项目组、重开 app——
/// 选过的那几条就都不在结果里了，界面上一个勾都看不见。用户原话：
/// 「我没有看到我选了那 3 个，我不知道是不是我那 3 个」。
///
/// 落地的是**信息**，不是视频本体：
/// - 名字/台词/画面描述/时长：几百字节，随任务一起存，重开就有；
/// - 首帧图：下载成本地文件（[thumbPath]）。素材库给的是签名地址，
///   一天就过期，存 URL 等于存一张迟早打不开的图；
/// - 视频本体不预下载——一个单元可以挑好几条、一条几十兆，而真正要用它
///   是在预览合成和导出的时候，那两处本来就按 id 现取。
@immutable
class PickedMaterial {
  final int id;
  final String name;

  /// 这条素材原本在说什么
  final String voiceover;

  /// 画面描述（没有台词时退回它）
  final String sceneDescription;

  /// 首帧图在本地的路径；没下下来时为 null（托盘照样显示，只是没有图）
  final String? thumbPath;

  /// 探测到的时长；探不出来时为 null——不要用 0 冒充
  final int? durationMs;

  /// 画面里烧着的文字（字幕、贴片文案、品牌角标）。
  ///
  /// **null 是「还没看过」，空列表才是「看过、画面干净」**——两者绝不能混：
  /// 我们换画面时还要往上再烧一行台词字幕，底下压着别家品牌的一句话，
  /// 两套字幕叠在一起、内容还毫不相干，片子直接废。把「没看过」当成
  /// 「干净」就是静默放行。真机撞到过：素材库的描述写「成人给小孩按摩
  /// 额头」，画面底部烧着「冰冰凉凉的好舒服呀」。
  final List<String>? burnedText;

  /// 画面里露出的产品是谁家的（读画面上的包装、logo）。
  ///
  /// **null 有两种含义，由 [burnedText] 区分**：整份检查没做过时它当然是
  /// null；查过了还是 null，表示画面里没有产品露出（纯场景镜头）。
  ///
  /// 为什么要记它：产品露出镜头**不能跨品牌换**。台词说「滴露新款消毒液」
  /// 而画面是若也洗发水直播间，片子自己打自己的脸——2026-08-28 真机上就
  /// 这样交付过一条成片。而素材库给的画面描述里既不写品牌也不写 logo。
  final String? productBrand;

  /// 上面那次画面自查看了几帧。null = 没查过。
  ///
  /// **一帧和三帧的结论份量不一样**：界面挑素材那一刻只有一张首帧图，
  /// 一帧会漏报产品露出（真机：素材 114801 首帧是滴露瓶、中段是微波炉
  /// 内部）。命令行提交方案时素材已经在本地、能抽头中尾三帧——记下帧数，
  /// 三帧的结论才能顶掉先前的单帧结论，界面看漏的那一次不至于被固化。
  final int? framesSeen;

  const PickedMaterial({
    required this.id,
    required this.name,
    this.voiceover = '',
    this.sceneDescription = '',
    this.thumbPath,
    this.durationMs,
    this.burnedText,
    this.productBrand,
    this.framesSeen,
  });

  /// 这条素材的画面**看全了**（拿到过多帧）。单帧看过不算看全
  bool get frameCheckComplete => (framesSeen ?? 0) >= 3;

  /// 看过没有。没看过时界面要说「未检查」，不能显示成「无字」
  bool get burnedTextChecked => burnedText != null;

  /// 确定画面上烧着字
  bool get hasBurnedText => burnedText?.isNotEmpty ?? false;

  /// 画面里有产品露出。这类镜头**不能跨品牌换**；纯场景镜头才可以
  bool get hasProduct => productBrand != null;

  /// 托盘上显示什么：台词 → 画面描述 → 素材名。三样都空时由调用方兜底
  String get label => voiceover.isNotEmpty
      ? voiceover
      : (sceneDescription.isNotEmpty ? sceneDescription : name);

  PickedMaterial withThumb(String? path) => PickedMaterial(
        id: id,
        name: name,
        voiceover: voiceover,
        sceneDescription: sceneDescription,
        thumbPath: path,
        durationMs: durationMs,
        burnedText: burnedText,
        productBrand: productBrand,
        framesSeen: framesSeen,
      );

  /// 记下这次画面自查的结果（烧字 + 产品露出品牌）
  PickedMaterial withFrameCheck(FrameCheck check) => PickedMaterial(
        id: id,
        name: name,
        voiceover: voiceover,
        sceneDescription: sceneDescription,
        thumbPath: thumbPath,
        durationMs: durationMs,
        burnedText: List.unmodifiable(check.burnedText),
        productBrand: check.productBrand,
        framesSeen: check.framesSeen,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (voiceover.isNotEmpty) 'voiceover': voiceover,
        if (sceneDescription.isNotEmpty) 'sceneDescription': sceneDescription,
        if (thumbPath != null) 'thumbPath': thumbPath,
        if (durationMs != null) 'durationMs': durationMs,
        // 没查过（null）就整个键不写：读回来仍然是「没查过」
        if (burnedText != null) 'burnedText': burnedText,
        if (productBrand != null) 'productBrand': productBrand,
        if (framesSeen != null) 'framesSeen': framesSeen,
      };

  /// 宽松解析：畸形的那一条跳过，不牵连整份任务——任务读不出来的代价是
  /// 「我的任务不见了」，比少一张缩略图严重得多
  static PickedMaterial? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! int) {
      AppLog.warn('已选素材缺少 id，跳过这一条');
      return null;
    }
    return PickedMaterial(
      id: id,
      name: raw['name'] is String ? raw['name'] as String : '素材 #$id',
      voiceover: raw['voiceover'] is String ? raw['voiceover'] as String : '',
      sceneDescription: raw['sceneDescription'] is String
          ? raw['sceneDescription'] as String
          : '',
      thumbPath: raw['thumbPath'] is String ? raw['thumbPath'] as String : null,
      durationMs: raw['durationMs'] is int ? raw['durationMs'] as int : null,
      burnedText: raw['burnedText'] is List
          ? List.unmodifiable([
              for (final e in raw['burnedText'] as List)
                if (e is String) e,
            ])
          : null,
      productBrand:
          raw['productBrand'] is String ? raw['productBrand'] as String : null,
      framesSeen: raw['framesSeen'] is int ? raw['framesSeen'] as int : null,
    );
  }

  static List<PickedMaterial> parseList(Object? raw) {
    if (raw is! List) return const [];
    return List.unmodifiable([
      for (final item in raw) ?tryFromJson(item),
    ]);
  }

  @override
  bool operator ==(Object other) =>
      other is PickedMaterial &&
      other.id == id &&
      other.name == name &&
      other.voiceover == voiceover &&
      other.sceneDescription == sceneDescription &&
      other.thumbPath == thumbPath &&
      other.durationMs == durationMs &&
      _sameText(other.burnedText, burnedText) &&
      other.productBrand == productBrand &&
      other.framesSeen == framesSeen;

  static bool _sameText(List<String>? a, List<String>? b) {
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(id, name, voiceover, sceneDescription,
      thumbPath, durationMs, Object.hashAll(burnedText ?? const []),
      productBrand, framesSeen);

  @override
  String toString() => 'PickedMaterial($id, $name)';
}
