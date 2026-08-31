import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **参考镜的首帧要能直接拿去搜。**
///
/// 妙啊的三种向量检索里，以图搜视频是复刻场景最该用的那一种——要复刻的
/// 画面就在手上，直接拿它找同类，比让 AI 先把画面写成一句话、再拿那句话
/// 去匹配别人写的另一句话准得多。中间那层文字转译很不稳：同一个镜头两次
/// 写出来的措辞不一样，搜出来的东西就不一样。
///
/// 而这条路此前是断的：`--like-image` 只吃 OSS key，参考镜的首帧却只在
/// 本地（打标时 ffmpeg 抽的）；入口也只长在候选卡上——手里攥着要复刻的
/// 那一帧，却得先用文字搜一轮、从结果里挑一条差不多的，再拿它去找相似。
void main() {
  test('参考镜卡上有「画面相似」入口', () {
    final src =
        File('lib/features/director/find_shots_sheet.dart').readAsStringSync();
    expect(src, contains("shots-ref-similar-"),
        reason: '入口只长在候选卡上的话，最准的那条路等于没开');
    expect(src, contains('_searchSimilarByFrame'),
        reason: '要能拿一张本地帧去搜，而不是只认库里素材的 fileKey');
  });

  test('两处叫同一个名字', () {
    final src =
        File('lib/features/director/find_shots_sheet.dart').readAsStringSync();
    expect(src.contains("_modePill('画面相似'"), isTrue);
    expect(src.contains("'找相似'"), isFalse,
        reason: '同一件事叫两个名字，人会以为是两个功能');
  });

  test('本地帧先传上去，且按内容指纹只传一次', () {
    final src =
        File('lib/core/miaoa/query_frame_uploader.dart').readAsStringSync();
    expect(src, contains('sha256'),
        reason: '按路径判重，同一帧换个名字就白传一次；'
            '按「文件在不在」判重会把上一张的结果放出来');
    expect(src, contains("'ossId'"),
        reason: '上传返回里的 ossId 才是 --like-image 要的那个 key');
  });

  test('搜不成就直说，不许悄悄退回文字搜', () {
    final src =
        File('lib/core/miaoa/query_frame_uploader.dart').readAsStringSync();
    expect(src, contains('退回文字搜'),
        reason: '人点的是「画面相似」。给他一批按文字搜出来的东西，'
            '他不会知道自己看的根本不是相似画面');
  });

  test('点「画面相似」不许冒泡到整张参考镜卡', () {
    final src =
        File('lib/features/director/find_shots_sheet.dart').readAsStringSync();
    final btn = src.substring(src.indexOf("shots-ref-similar-") - 900,
        src.indexOf("shots-ref-similar-") + 200);
    expect(btn, contains('HitTestBehavior.opaque'),
        reason: '整张参考镜卡本身也可点（点它=用这一镜的画面描述搜）。'
            '不拦住这一下，点「画面相似」会顺带把模式改回「按画面描述」'
            '——搜是按图搜了，界面却显示成另一个模式');
  });

  test('已经有查询帧时，点「画面相似」直接切回去，不再提示「去点」', () {
    final src =
        File('lib/features/director/find_shots_sheet.dart').readAsStringSync();
    final pill = src.substring(src.indexOf("_modePill('画面相似'"));
    expect(pill.substring(0, 400), contains('_similarFileKey ?? '),
        reason: '人明明刚点过，还提示他去点，是把他当没做过');
  });
}
