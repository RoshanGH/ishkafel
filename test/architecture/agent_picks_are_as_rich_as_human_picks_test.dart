import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Agent 挑的素材，记录不该比人在界面上挑的**少字段**。
///
/// 这个缺口已经开过**三次**，每次都是同一个形状：某件事只长在界面那条路
/// （`PickedMaterialStore`）上，Agent 提交方案那条（`collectPickedMaterials`）
/// 不做，而后果要等人进了审核页才看得见。
///
/// 1. **素材时长**——不写就算不出倍速，Agent 交的方案导进剪映会被切掉
///    超出坑位的部分
/// 2. **画面自查**（烧字 + 产品露出品牌）——不看就是把一条会毁掉整片的
///    素材静默放行，而 Agent 恰恰是那个一口气挑几十条、人来不及一张张
///    看图的角色
/// 3. **首帧图**（2026-09-18 真机）——不下就是人进审核页看到一整屏
///    「画面还没抽出来」。用户原话：「经常会出现没有首帧图的那种情况，
///    就是全是黑的，但是鼠标放上去还能播放，其他的操作都正常的。」
///
/// 第三条最说明问题：**审核页的全部意义就是看图判断**（Agent 挑完、人来
/// 把关），看不到图这一步等于废了；而且 Agent 用得越多越常见——正好和
/// 「可视化验的是它的判断逻辑对不对」相反着来。
///
/// 这条守的是**装配**：`gatherPickedMaterials` 是 Agent 那条路的唯一入口，
/// 三样必须都接上。漏一样，测试当场红。
void main() {
  String gather() => _bodyOf(
      File('lib/cli/commands/apply_command.dart').readAsStringSync(),
      'Future<List<PickedMaterial>> gatherPickedMaterials');

  test('Agent 那条路把素材时长收下来', () {
    expect(gather(), contains('probeDurationMs:'),
        reason: '不写时长，取段退回「整条压缩」，短镜头照样十几二十倍快放');
  });

  test('Agent 那条路对素材做画面自查', () {
    expect(gather(), contains('checkFrame:'),
        reason: '烧字与产品露出只有看图才知道，两样都能毁掉整片');
  });

  test('Agent 那条路把首帧图也下下来', () {
    expect(gather(), contains('fetchThumb:'),
        reason: '不下首帧图，人进审核页看到的是一整屏「画面还没抽出来」——'
            '而审核页的全部意义就是看图判断（2026-09-18 真机）');
  });

  test('首帧图的落点和界面那条路是同一个目录、同一份实现', () {
    expect(gather(), contains('PickedThumbs'),
        reason: '各写一份迟早不一样——界面写进 picked_thumbs/<任务>/，'
            'Agent 写到别处的话，审核页照样找不到');
    final store =
        File('lib/features/picking/picked_material_store.dart').readAsStringSync();
    expect(store, contains('PickedThumbs'),
        reason: '界面那条路也要走同一份，否则「同一件事有两处说了算」');
    expect(store, isNot(contains('writeAsBytes')),
        reason: '下载与落盘只该留在 PickedThumbs 里一处');
  });

  test('首帧图按内容非空判命中，不按文件名存在判', () {
    final thumbs =
        File('lib/core/replacement/picked_thumbs.dart').readAsStringSync();
    expect(thumbs, contains('lengthSync() > 0'),
        reason: '上一次没下完留下的空壳会一直被当成命中端出来，'
            '而界面只看路径存不存在——画出来是一整块纯色底且一个字都不说');
  });
}

/// 把某个顶层函数的函数体抠出来（到下一个顶层声明为止）
String _bodyOf(String src, String signature) {
  final start = src.indexOf(signature);
  if (start == -1) {
    throw StateError('找不到 $signature——它被改名了？这条守卫要跟着改');
  }
  final rest = src.substring(start);
  final end = rest.indexOf('\n}\n');
  return end == -1 ? rest : rest.substring(0, end);
}
