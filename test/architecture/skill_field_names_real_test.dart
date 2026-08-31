import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/agent_skill/agent_skill_doc.dart';

/// 手册里写的字段名要和真实输出对得上。
///
/// 验收 Agent 撞的原样：手册「挑镜头」那张表写的是 `description`，实际
/// 输出里叫 `sceneDescription`；写 `id`，实际叫 `materialId`。它照手册
/// 写 jq，拿到一整列 `null`——**第一反应是「检索坏了」**，而不是
/// 「手册写错了」。字段名这种东西错一个字，排查方向就整个偏了。
void main() {
  test('候选那节要给真名，别让人照着写出一列 null', () {
    // 手册里介绍 candidates 的那一段
    final idx = agentSkillMarkdown.indexOf('`candidates[]`');
    expect(idx, greaterThan(0), reason: '手册连候选这张表都没有了？回来看看');
    final section = agentSkillMarkdown.substring(idx, idx + 400);
    for (final real in ['materialId', 'sceneDescription']) {
      expect(section, contains(real),
          reason: '真实输出里是 $real，手册不写清楚，'
              '照着写的 jq 会拿到一整列 null');
    }
  });

  test('这两个名字在代码里确实是这么叫的——不然这条测试守错了方向', () {
    final src = File('lib/cli/script_shot_context.dart').readAsStringSync() +
        File('lib/cli/commands/script_command.dart').readAsStringSync();
    expect(src, contains('materialId'));
    expect(src, contains('sceneDescription'));
  });
}
