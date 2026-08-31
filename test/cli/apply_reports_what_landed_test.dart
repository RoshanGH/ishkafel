import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **报「存进去了什么」，不是报「你提交了什么」。**
///
/// 真机上第 20、24 行拿到的是：
///
/// ```json
/// {"ok":true,"applied":1,"changed":"给 1 行挑了镜头"}
/// ```
///
/// 而盘上是 0 个镜头。界面同时诚实地写着「第 20、24 行 还没挑镜头」——
/// **命令行撒了谎**。只信退出码的 Agent 会交付两个空坑位的片子，
/// 而且整条链路上没有任何一处会提醒他。
///
/// 这不是「某个函数有 bug」那么简单：`applied` 的数字一直是从**提交内容**
/// 算出来的，跟落盘结果没有任何关系。就算今天修好那个吞镜头的分支，
/// 明天换个原因照样会静默落空。所以要在落盘之后回读一遍。
void main() {
  final src =
      File('lib/cli/commands/script_apply_command.dart').readAsStringSync();

  test('落盘后回读，空了就报失败', () {
    expect(src, contains('_picksThatLandedEmpty'),
        reason: '不回读的话，「说了」和「做了」永远对不上');
    expect(src, contains('return exitFailed'),
        reason: '落空了还返回 0，调用方只会当成功——'
            '这正是「静默降级」里最坏的一种');
  });

  test('要给能照做的下一步，不是只说失败', () {
    expect(src, contains('script peek'),
        reason: '素材没落到本地是最常见的原因，直接告诉他怎么补');
  });

  test('两边说的不一样时信盘上的', () {
    expect(src, contains('界面诚实'),
        reason: '把这段来历写下来——下次有人想「优化」掉这次回读时，'
            '得先读到它当初是怎么骗过人的');
  });
}
