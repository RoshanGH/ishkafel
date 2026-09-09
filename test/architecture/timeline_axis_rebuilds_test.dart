import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **切分改了，时间线的轴必须跟着重算。**
///
/// 2026-09-09 真机，用户原话：「连续合并两次就又是这个样子，返回首页再进去
/// 就显示正常了」——合并完两镜，那个单元的镜头轨尾部空出一截；退回任务列表
/// 再进来（整棵树重建）就好了。
///
/// 病灶：换轴那一步写在时间线区的 `LayoutBuilder` 里，而 LayoutBuilder
/// **只在尺寸变了才重跑**。改切分不改尺寸，于是那一步永远不跑，时间线继续
/// 用着改动之前那条轴——镜头在成片上的位置正是从轴里那份镜头列表算出来的，
/// 位置全是旧的。
///
/// 页面级 setState 早就为了播放性能移除了（播放时每秒 30 次重建整页），
/// 所以时间线区必须**自己监听编辑器**。属性栏那边栽过同一件事，结论一样：
/// 轴要在自己的重建里现算（见
/// `test/features/workbench/axis_refreshes_on_edit_test.dart`）。
void main() {
  test('时间线区包在 AnimatedBuilder(animation: editor) 里', () {
    final src =
        File('lib/features/workbench/workbench_body.dart').readAsStringSync();
    final i = src.indexOf('Widget _buildTimelineArea(');
    expect(i, greaterThan(0), reason: '方法改名了就更新这里');

    // 取到下一个方法为止
    final end = src.indexOf('Widget _buildTimelineToolbar(', i);
    final body = src.substring(i, end > 0 ? end : src.length);

    // 只看**紧挨着** LayoutBuilder 外面那一层：工具条那边本来就有一个
    // AnimatedBuilder，只查「有没有」会被它蒙混过去
    final layout = body.indexOf('LayoutBuilder(');
    expect(layout, greaterThan(0), reason: '时间线区没有 LayoutBuilder 了？');
    final wrapper = body.lastIndexOf('Expanded(', layout);
    expect(wrapper, greaterThan(0));
    final between = body.substring(wrapper, layout);

    expect(between, contains('AnimatedBuilder('),
        reason: '时间线区不监听编辑器的话，改完切分它不重建——'
            '轴停在改动之前，镜头位置全是旧的，单元尾部空出一截');
    expect(between, contains('animation: editor'),
        reason: '要监听的是编辑器（切分的真相），不是别的');
  });
}
