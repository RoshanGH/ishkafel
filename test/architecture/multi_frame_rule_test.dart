import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **一帧判不出一条素材/一个镜头里在发生什么**——这个道理已经在两条路上
/// 各栽过一次：
///
/// 1. `taggers.dart`：单帧只给「主播在仓库中直播带货」，3 帧才给出
///    「主播转动身体依次指向不同方向的货位」，描述动作的标签组打不准
/// 2. `local_frame_check.dart`：只抽中段那一帧，于是素材 114801（首帧是
///    一排 Dettol 滴露瓶、尾帧右上角也有一瓶、唯独中段是微波炉内部）
///    被记成「无产品露出」——而品牌错位会直接毁掉整条成片
///
/// 第二次是在**明明写着第一次教训的代码旁边**重犯的。这道测试盯着：
/// 凡是「看素材画面下判断」的地方，都必须是多帧。
void main() {
  test('看画面下判断的地方都要送多帧，不许退回单帧', () {
    final sources = {
      'lib/core/ai/local_frame_check.dart': '素材画面自查（烧字 + 产品露出品牌）',
      'lib/core/analysis/shot_frame_sampler.dart': '视觉镜头打标',
    };
    for (final entry in sources.entries) {
      final file = File(entry.key);
      if (!file.existsSync()) continue;
      final src = file.readAsStringSync();
      expect(
        RegExp(r'chatVision\s*\(').hasMatch(src),
        isFalse,
        reason: '${entry.value}（${entry.key}）用了单帧的 chatVision。'
            '一帧看不全：产品可能只在某几秒出现，动作更是一帧看不出来。'
            '要用 chatVisionFrames 把几帧送进同一次调用',
      );
    }
  });

  test('画面自查必须真的抽不止一个采样点', () {
    final src =
        File('lib/core/ai/local_frame_check.dart').readAsStringSync();
    // 采样点由 _sampleSeconds 给出，它必须能返回多个
    expect(src, contains('_sampleSeconds'));
    expect(RegExp(r'total \* 0\.\d').allMatches(src).length, greaterThan(1),
        reason: '只有一个采样点就是单帧的老路');
  });

  test('单帧的结论不许被当成看全了', () {
    final src =
        File('lib/cli/plan_submission.dart').readAsStringSync();
    expect(src, contains('frameCheckComplete'),
        reason: '界面挑素材时只有一张首帧图。用「查过没有」当跳过条件的话，'
            '界面那次单帧漏报就被永久固化了——要用「看全了没有」');
  });
}
