import 'dart:convert';
import 'dart:io';

import 'ark_chat_client.dart';

/// 看一眼素材画面，一次问清两件**只有看图才知道、而且都能毁掉整片**的事。
///
/// 为什么这两件事绑在一起：它们同源——素材库给的画面描述里两样都看不出来，
/// 而且都要等到成片出来才发现。既然都要看图，就一次问完：多问一个问题几乎
/// 不加钱，多跑一次调用是成倍的。
class FrameCheck {
  /// 画面上烧着的文字（字幕、贴片文案、品牌角标）。空 = 画面干净。
  ///
  /// 换上这条素材之后我们还要再烧一行台词字幕，两层字叠在一起、内容还
  /// 毫不相干——片子直接废。真机撞到过：描述写「成人给小孩按摩额头」，
  /// 画面底部烧着别家品牌的「冰冰凉凉的好舒服呀」。
  final List<String> burnedText;

  /// 画面里露出的产品是谁家的（读画面上的包装、logo）。
  /// **null = 画面里没有产品露出**，不是「认不出来」——认不出来也给 null，
  /// 因为瞎猜一个牌子比承认不知道更糟。
  ///
  /// 台词说「滴露新款消毒液」而画面是若也洗发水直播间，片子自己打自己的脸。
  /// 2026-08-28 真机上就这样交付过一条带错误品牌镜头的成片。
  final String? productBrand;

  /// 这个结论是看了几帧得出来的。
  ///
  /// **一帧和三帧的结论份量不一样**：一帧会漏报产品露出（真机：素材 114801
  /// 首帧是滴露瓶、中段是微波炉内部）。界面挑素材那一刻只有一张首帧图，
  /// 命令行提交方案时素材已经在本地、能抽头中尾三帧——记下帧数，
  /// 后来的三帧结论才能顶掉先前的单帧结论。
  final int framesSeen;

  const FrameCheck({
    this.burnedText = const [],
    this.productBrand,
    this.framesSeen = 1,
  });

  /// 画面里有产品露出。这类镜头**不能跨品牌换**；纯场景镜头才可以
  bool get hasProduct => productBrand != null;
}

/// 多帧时要说明「这几张是同一条素材的连续采样」——不说的话模型会把它们
/// 当成几段无关的素材分别回答，然后只答其中一张
String _promptFor(int frameCount) => frameCount > 1
    ? '这 $frameCount 张图是同一条短视频素材按时间先后采样的画面'
        '（依次为开头、中间、结尾）。**任何一张里出现的问题都算这条素材的**。'
        '\n$frameCheckPrompt'
    : frameCheckPrompt;

/// 提示词单独提出来：措辞直接决定漏报率，改它是改行为，要能被测试盯住。
const String frameCheckPrompt = '看这些短视频画面，回答两个问题，只回 JSON。\n'
    '一、画面里有没有**烧录在画面上的文字**？字幕、贴片文案、品牌角标、'
    '促销价签都算；实际拍到的实物上印的字（如包装盒上的商品名）不算。'
    '把看到的文字原样列进 "burnedText" 数组（几张图上的字合在一起），'
    '画面干净就给空数组。\n'
    '二、画面里有没有**产品露出**（有人拿着、摆着、或在用某个商品）？'
    '有的话把那个产品的品牌写进 "productBrand"（读包装和 logo）。'
    '画面里没有产品、或者认不出是什么牌子，一律给 null——'
    '**瞎猜一个牌子比承认不知道更糟**。\n'
    '格式：{"burnedText": ["..."], "productBrand": "..." 或 null}';

/// 「看不出来」的各种说法。模型有时不肯给 null，改说「无」「未知」——
/// 那些都不是品牌，当成没有产品处理
const Set<String> _notABrand = {
  '无', '没有', '未知', '不确定', '看不清', '不清楚', '空',
  'none', 'null', 'n/a', 'na', 'unknown', 'unclear', 'no', 'nil',
};

abstract class FrameChecker {
  /// [imagePaths] 是同一条素材按时间先后采样的几帧。
  ///
  /// **为什么收多帧**：一帧判不出一条素材里有没有产品露出。真机上栽过——
  /// 素材 114801 首帧是一排 Dettol 滴露瓶、尾帧右上角也有一瓶，唯独中段
  /// 那一帧是微波炉内部什么都没有，而我们只送了中段，于是记成「无产品露出」。
  /// （`taggers.dart` 里早就写过同一个道理，这是它在第二条路上重来一遍。）
  ///
  /// **看不出来就要抛**——返回一个「干净、没产品」的结果等于说画面没问题，
  /// 那是静默降级。
  Future<FrameCheck> check(List<String> imagePaths);
}

class ArkFrameChecker implements FrameChecker {
  final ArkChatClient chat;

  /// 判断题，用便宜的视觉模型即可；不传走客户端默认
  final String? model;

  const ArkFrameChecker(this.chat, {this.model});

  @override
  Future<FrameCheck> check(List<String> imagePaths) async {
    if (imagePaths.isEmpty) {
      throw ArgumentError('一帧都没有就没什么可看的——别把它当成「画面没问题」');
    }
    final frames = [
      for (final path in imagePaths) await File(path).readAsBytes(),
    ];
    final reply = await chat.chatVisionFrames(
      prompt: _promptFor(frames.length),
      frames: frames,
      maxTokens: 256,
      // 判断题：同一张图重看一次不该给出另一个答案
      temperature: 0,
      model: model,
    );
    return parseFrameCheck(reply, framesSeen: frames.length);
  }
}

/// 从模型回复里取出这两件事。解析不出来就抛——「解析失败」和「画面没问题」
/// 是两件事，混为一谈会让一条会毁掉整片的素材悄悄进片子。
FrameCheck parseFrameCheck(String reply, {int framesSeen = 1}) {
  final start = reply.indexOf('{');
  final end = reply.lastIndexOf('}');
  if (start < 0 || end <= start) {
    throw FormatException('看不懂模型对画面自查的回答：$reply');
  }
  final json = jsonDecode(reply.substring(start, end + 1));
  final raw = json is Map ? json['burnedText'] : null;
  if (raw is! List) {
    // 缺这个键是「没答」，不是「答了干净」
    throw FormatException('模型没给 burnedText：$reply');
  }
  return FrameCheck(
    burnedText: [
      for (final e in raw)
        if (e is String && e.trim().isNotEmpty) e.trim(),
    ],
    productBrand: _brandOf(json is Map ? json['productBrand'] : null),
    framesSeen: framesSeen,
  );
}

String? _brandOf(Object? raw) {
  if (raw is! String) return null;
  final t = raw.trim();
  if (t.isEmpty || _notABrand.contains(t.toLowerCase())) return null;
  return t;
}
