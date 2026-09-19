import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/commands/script_apply_command.dart';

/// `scriptApplyKinds` 里每一种（`shots` 除外）都必须在 `scriptApplyOpNames`
/// 里登记一个 op 名——不能靠 `?? 'script.apply.$what'` 这种兜底默默凑出一个
/// 没人管的 op 名（2026-09-17 复审指出：带兜底就等于没受控，新增一个 `what`
/// 照旧静默多出一个 op 名）。
///
/// `runScriptApplyCommand` 里现在有一道防御性的早退检查兜底，但**这条测试
/// 才是第一道关卡**：新增一种 `apply` 子类型时，这条测试会先红，逼着人
/// 去 `scriptApplyOpNames` 里补一条，而不是等运行时才发现漏了。
void main() {
  test('scriptApplyKinds 里每一项（shots 除外）都在 scriptApplyOpNames 里登记了',
      () {
    final missing = [
      for (final kind in scriptApplyKinds)
        if (kind != 'shots' && !scriptApplyOpNames.containsKey(kind)) kind,
    ];
    expect(missing, isEmpty,
        reason: '这些 apply 子类型没有登记 op 名，落盘时会走 null 断言'
            '崩掉（或者曾经：静默拼出一个没人管的 op 名）：$missing。'
            '去 script_apply_command.dart 的 scriptApplyOpNames 里补一条');
  });

  test('scriptApplyOpNames 里没有多余的、不在 scriptApplyKinds 里的项', () {
    final extra = [
      for (final k in scriptApplyOpNames.keys)
        if (!scriptApplyKinds.contains(k)) k,
    ];
    expect(extra, isEmpty,
        reason: '这些 op 名登记了但对应的子类型已经不在 scriptApplyKinds '
            '里，是死代码：$extra');
  });
}
