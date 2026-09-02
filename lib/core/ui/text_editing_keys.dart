import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;

/// **人正在输入框里打字吗。**
///
/// 页面级快捷键必须在这种情况下让路——不拦截空格/方向键，让它们走文本编辑
/// 流程，而不是被当成播放/暂停或逐帧指令。做法：从当前 `primaryFocus` 对应的
/// Element 往上找有没有 [EditableText] 祖先（`TextField` 内部由它承载编辑）。
bool isEditableTextFocused() {
  final element = FocusManager.instance.primaryFocus?.context;
  if (element == null) return false;
  return element.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// **输入框上方的按键放行表：把这些键留给文本框自己。**
///
/// 真机事故：编导台写脚本时**中文输入法打不出汉字，粘贴却可以**。
/// 根因是全页快捷键把空格绑成了「播放/暂停」——而中文输入法在拼音阶段
/// 按空格是**选词上屏**。组合期间文本框并不「消费」这个空格（它没插入
/// 字符），于是被页面级快捷键抢走，拼音永远上不了屏。
///
/// [DoNothingAndStopPropagationIntent] 让这些键**停在输入框这一层**，
/// 由它自己按系统默认行为处理，不再冒泡到页面级。
///
/// 表里每一个键在输入框里都有自己的天职：
/// - 空格：输入空格；**输入法组合时是选词**
/// - ←/→：移动光标；组合时切换候选
/// - Esc：取消输入法的组合
/// - ⌘A / ⌘Z / ⇧⌘Z：全选、撤销、重做**这段文本**，不是整个文档
const Map<ShortcutActivator, Intent> textEditingPassthrough =
    <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.space):
      DoNothingAndStopPropagationIntent(),
  SingleActivator(LogicalKeyboardKey.arrowLeft):
      DoNothingAndStopPropagationIntent(),
  SingleActivator(LogicalKeyboardKey.arrowRight):
      DoNothingAndStopPropagationIntent(),
  SingleActivator(LogicalKeyboardKey.escape):
      DoNothingAndStopPropagationIntent(),
  SingleActivator(LogicalKeyboardKey.keyA, meta: true):
      DoNothingAndStopPropagationIntent(),
  SingleActivator(LogicalKeyboardKey.keyZ, meta: true):
      DoNothingAndStopPropagationIntent(),
  SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true):
      DoNothingAndStopPropagationIntent(),
};

/// 把一个输入框（或一片输入区）包起来，让上面那些键归它自己。
class TextEditingKeys extends StatelessWidget {
  final Widget child;
  const TextEditingKeys({super.key, required this.child});

  @override
  Widget build(BuildContext context) =>
      Shortcuts(shortcuts: textEditingPassthrough, child: child);
}
