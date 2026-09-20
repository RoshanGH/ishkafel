import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// 设计文档 §8.1 的第三条架构测试：**取时间的路径只有一条。**
///
/// 这条一直没写，于是「成片帧轴」只立了一半——`ComposedFrames` 内部把段头
/// 补成对称的那个方法是私有的，下游的 `heard_words` 和 `subtitle_view`
/// 只能退回裸的 `FrameSpan.fromMs` / `frameIndex`，对称性在真正要用它的
/// 两处全丢了。真机任务 #1（51 镜）：相邻两词共享同一帧 375/487、相邻两段
/// 字幕共享同一帧 4/11、5 个词整词落在本镜帧区间之外却仍被算进本镜并报成
/// `wordSplit`——而手册教 Agent 拿 `heard` 和 `lines` 并排看，它照手册会把
/// 对的那一镜改错。
void main() {
  test('把毫秒变成帧只许走一条路——ComposedFrames', () {
    // 设计文档 §2.6：选「帧」而不是「毫秒」的唯一理由是相邻段不共享任何一帧。
    // 而 FrameSpan.fromMs 只在段尾做了修正、段头是直接四舍五入，
    // ComposedFrames.spanOfMs 才把段头也补成对称的。裸调的地方就会丢掉
    // 这个保证——真机上 487 对相邻词里有 375 对共享了同一帧
    for (final f in [
      'lib/cli/subtitle_view.dart',
      'lib/core/subtitle/heard_words.dart',
      'lib/core/subtitle/subtitle_problems.dart',
    ]) {
      final src = File(f).readAsStringSync();
      expect(src.contains('FrameSpan.fromMs('), isFalse,
          reason: '$f 裸调了 FrameSpan.fromMs');
      expect(src.contains('frameIndex('), isFalse,
          reason: '$f 裸调了 frameIndex');
      // **C1 的原始 bug 写的就是 frameAt**（`frames.frameAt(unitStart + from)`），
      // 漏掉它的话这条测试正好漏在它本该拦住的那个写法上——复评把
      // heard_words 整段退回 bug 形态，这条测试照样全绿。
      // 只扫这三个下游文件：ComposedFrames 自己内部要用 frameAt
      expect(src.contains('frameAt('), isFalse,
          reason: '$f 裸调了 frameAt——C1 的原始 bug 就是这个写法，'
              '首尾各四舍五入一次，段头对称全丢');
    }
  });

  test('那条唯一的路要真存在，而且是公开的', () {
    // 上面那条是「不许裸调」，它自己不保证替代品还在。`spanOfMs` 被改名、
    // 被改回私有、或者整个删掉的话，上面那条会安安静静地全绿——
    // 这个项目的白名单式架构测试已经空转过不止一次
    final src =
        File('lib/core/timeline/composed_frames.dart').readAsStringSync();
    expect(src.contains('FrameSpan spanOfMs('), isTrue,
        reason: 'ComposedFrames.spanOfMs 不见了，上面那条测试就是空转的');
  });
}
