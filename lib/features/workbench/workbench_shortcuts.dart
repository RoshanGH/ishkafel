import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 审片台页面级全局播放快捷键（空格播放/暂停、←/→ 逐帧步进）。
///
/// 从 `workbench_page.dart` 拆出：这套 Intent/Action 专门用于包裹整个页面
/// body（三栏 + 时间线），解决"焦点一旦不在 PlayerPanel 子树上，空格/方向
/// 键就失效"的问题（对齐剪映/FCP「空格全局播放」的体感）——`player_panel.dart`
/// 内部另有一份同类 Shortcuts 仅覆盖自身子树，两者是不同的类、不冲突，
/// PlayerPanel 自己持有焦点时其内部快捷键先响应，其余情况下由这里兜底。

/// 页面级「切换播放/暂停」意图（Shortcuts→Actions 转发用）
class PageTogglePlayIntent extends Intent {
  const PageTogglePlayIntent();
}

/// 页面级逐帧步进意图：[frames] 为正前进、为负后退
class PageStepFrameIntent extends Intent {
  final int frames;
  const PageStepFrameIntent(this.frames);
}

/// 判断当前键盘焦点是否落在可编辑文本控件（如台词输入框）内。
///
/// 页面级快捷键必须在这种情况下"放行"——不拦截空格/方向键，让它们正常
/// 走文本编辑流程，而不是被误当成播放/暂停或逐帧指令。做法：从当前
/// `primaryFocus` 对应的 Element 向上找是否存在 [EditableText] 祖先
/// （`TextField`/`TextFormField` 内部都由 `EditableText` 承载实际编辑）。
bool isEditableTextFocused() {
  final element = FocusManager.instance.primaryFocus?.context;
  if (element == null) return false;
  return element.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// 页面级「切换播放/暂停」Action：焦点在文本框时禁用（`isEnabled` 返回
/// false），此时 `Actions`/`ShortcutManager` 会把按键视为"本层未处理"，
/// 继续向外层（乃至文本框自身的编辑逻辑）传递，而不是被这里吞掉。
class PageTogglePlayAction extends Action<PageTogglePlayIntent> {
  PageTogglePlayAction(this._callback);
  final VoidCallback _callback;

  @override
  bool isEnabled(PageTogglePlayIntent intent) => !isEditableTextFocused();

  @override
  void invoke(PageTogglePlayIntent intent) => _callback();
}

/// 页面级「逐帧步进」Action，同上原因用 `isEnabled` 在文本框聚焦时让路
class PageStepFrameAction extends Action<PageStepFrameIntent> {
  PageStepFrameAction(this._callback);
  final ValueChanged<int> _callback;

  @override
  bool isEnabled(PageStepFrameIntent intent) => !isEditableTextFocused();

  @override
  void invoke(PageStepFrameIntent intent) => _callback(intent.frames);
}

/// 快捷键激活表：空格→切换播放，←/→→逐帧步进 ±1 帧
const Map<ShortcutActivator, Intent> workbenchPlaybackShortcuts =
    <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.space): PageTogglePlayIntent(),
  SingleActivator(LogicalKeyboardKey.arrowLeft): PageStepFrameIntent(-1),
  SingleActivator(LogicalKeyboardKey.arrowRight): PageStepFrameIntent(1),
};

/// 快捷键动作表：组装 [PageTogglePlayAction]/[PageStepFrameAction]
Map<Type, Action<Intent>> workbenchPlaybackActions({
  required VoidCallback onTogglePlay,
  required ValueChanged<int> onStepFrame,
}) =>
    <Type, Action<Intent>>{
      PageTogglePlayIntent: PageTogglePlayAction(onTogglePlay),
      PageStepFrameIntent: PageStepFrameAction(onStepFrame),
    };
