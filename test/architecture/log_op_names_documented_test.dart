import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/commands/script_apply_command.dart';

/// 代码里所有 `TaskMutation(...).apply(op: '...')` 用到的 op 字面量，
/// 都必须在 `docs/AGENT_SKILL.md` 的「日志里的 op 名对照表」里登记过——
/// 那份表自称「可能出现的 op 有哪些」，漏一条就等于 Agent grep 不到
/// （2026-09-18 真机复审逐条核对代码里的 op 字面量，发现 `voice.upload`
/// 当时漏了）。
///
/// 只扫 `lib/cli`：这批改造（Task 6）的写入口全在这里；`scriptApplyKinds`
/// 那一批动态拼出来的 op 名从 `scriptApplyOpNames`（已受控，见
/// `script_apply_op_names_registered_test.dart`）直接取值，不用正则猜。
void main() {
  test('lib/cli 里所有静态 op 字面量都在手册的 op 名对照表里登记了', () {
    final opNames = <String>{...scriptApplyOpNames.values};
    // 只认紧跟在 `op:` 后面的**纯字符串字面量**——`[^'\$]` 挡住
    // `op: '${e['op'] ?? 'set'}'` 这种记录字段初始化（跟 TaskMutation.apply
    // 毫无关系，只是字段名也叫 op），不让它混进来
    final literalOp = RegExp(r"op:\s*'([^'\$][^']*)'");
    for (final f in Directory('lib/cli')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final content = f.readAsStringSync();
      for (final m in literalOp.allMatches(content)) {
        opNames.add(m.group(1)!);
      }
    }

    final doc = File('docs/AGENT_SKILL.md').readAsStringSync();
    final missing = [
      for (final op in opNames)
        if (!doc.contains('`$op`')) op,
    ]..sort();

    expect(missing, isEmpty,
        reason: '这些 op 名代码里在用，但 docs/AGENT_SKILL.md 的「日志里的 '
            'op 名对照表」没登记，Agent 查日志时 grep 不到：\n'
            '${missing.join('\n')}\n'
            '改完记得 dart run tool/gen_agent_skill.dart 重新生成内嵌常量');
  });
}
