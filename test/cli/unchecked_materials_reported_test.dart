import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 素材还没落到本地时，画面自查整批跳过——`framesSeen` 全是 null。
///
/// 手册反复讲「null 是没看成、不是没问题」，**却从没说过怎么让它看得成**。
/// 验收 Agent 只能自己摸：先 `script peek --materials` 把素材拉到本地，
/// 再把同一份提交原样重提一遍。而正是那一轮才查出——
///
/// > 行 10 的素材 114798，画面底部烧着别的片子的台词字幕
///
/// 位置正好是我们要烧台词字幕的地方。**照第一轮直接导出，交付的就是
/// 两层字幕打架的废片。**
///
/// 所以「有几条没看成」必须当场点名并给出补救命令，不能只往日志里
/// 写一行 warn——那行 warn 混在几十行输出里，没人会当回事。
void main() {
  final src =
      File('lib/cli/commands/script_apply_command.dart').readAsStringSync();

  test('提交回填后要报出没看成的素材', () {
    expect(src, contains('uncheckedMaterials'),
        reason: '不报的话，「没看成」和「都干净」在输出里长得一模一样');
  });

  test('要给能照着敲的补救命令，不是只描述状态', () {
    expect(src, contains('script peek'),
        reason: 'Agent 当初是自己摸出这条路的——软件手里明明有这个能力，'
            '却从没告诉过它');
    expect(src, contains('原样再提一次'),
        reason: '光下载不够，得重提一遍才会真的看图；漏掉这半句等于没说');
  });

  test('话要说明白后果，不能只说「未检查」', () {
    expect(src, contains('两层字'),
        reason: '「未检查」听起来像个可以忽略的提示；'
            '「整条片子废掉」才是它真正的分量');
  });
}
