import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **底片切出来的镜头是一等公民**，和原片切出来的一样齐全。
///
/// 产品负责人的原话：「正常的参考视频的台词语义单元里面的 S1、S2、S3
/// 要干嘛，你这边也是要干嘛的，都要走一遍。」
///
/// 这条守卫盯的是**两条路容易只补一边**：全片分析那条线加了什么，底片切分
/// 这条线也得有。它查不了语义，只能把「必须成对出现」的几件事钉住，
/// 加新东西时逼人回来看一眼这份清单。
void main() {
  String read(String path) {
    final f = File(path);
    expect(f.existsSync(), isTrue, reason: '$path 挪了位置就把这条守卫一起改');
    return f.readAsStringSync();
  }

  test('切点的判定依据：两条路都要贴到镜头上', () {
    // 全片：AnalysisPipeline._withBoundaryTrace
    expect(read('lib/core/analysis/analysis_pipeline.dart'),
        contains('BoundaryTrace('));
    // 底片：UnitSegmenter._withBoundaryTrace
    expect(read('lib/core/analysis/unit_segmenter.dart'),
        contains('BoundaryTrace('),
        reason: '不贴的话，同样是一刀，原片切的能回看依据、底片切的点开是空的');
  });

  test('打标：切完底片要接着打，不能让人拿着没标签的镜头去搜素材', () {
    final page = read('lib/features/workbench/workbench_page.dart');

    // 切分那条路走完要接上打标
    expect(page, contains('_retagBaseUnit'),
        reason: '底片镜头不打标，按画面/标签搜素材一条都搜不出来');
    final segmentAt = page.indexOf('Future<void> _segmentUnitBase');
    expect(segmentAt, greaterThan(-1));
    final segmentBody = page.substring(
        segmentAt, page.indexOf('Future<void> _unpinUnitBase'));
    expect(segmentBody, contains('_retagBaseUnit('),
        reason: '切分流程里要接着打标——原片那条线是分析时顺带打好的');
  });

  test('打标要认底片：抽帧不能跑去原片同一个时间点', () {
    expect(read('lib/core/analysis/tagging_service.dart'),
        contains('baseVideoPaths'),
        reason: '不认底片的话抽到的是另一段画面，标签张冠李戴而哪儿都不报错');
  });

  test('花钱的动作点之前要说清楚', () {
    final dialog = read('lib/features/workbench/base_pin_dialogs.dart');

    expect(dialog, contains('打标'), reason: '确认框要说这一下还会打标');
    expect(dialog, contains('花钱'), reason: '要花钱必须写出来');
  });
}
