import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/ui/text_editing_keys.dart';

// 「人正在输入框里打字吗」只有一份，放在 core/ui——编导台那边也要用它
export '../../core/ui/text_editing_keys.dart' show isEditableTextFocused;

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

/// 页面级「撤销」意图：转发到 [SegmentationEditorController.undo]
class PageUndoIntent extends Intent {
  const PageUndoIntent();
}

/// 页面级「重做」意图：转发到 [SegmentationEditorController.redo]
class PageRedoIntent extends Intent {
  const PageRedoIntent();
}

/// 走带意图：JKL 是所有视频工具通行的键位（J 反向 / K 停 / L 正向），
/// 用户会下意识去按。[direction] 为 -1/0/1。
class PageShuttleIntent extends Intent {
  final int direction;
  const PageShuttleIntent(this.direction);
}

/// 在相邻的台词语义单元/视觉镜头之间移动选中（[delta] 为 +1/-1）
class PageSelectAdjacentIntent extends Intent {
  final int delta;
  const PageSelectAdjacentIntent(this.delta);
}

/// 跳到片头/片尾
class PageSeekEdgeIntent extends Intent {
  final bool toStart;
  const PageSeekEdgeIntent({required this.toStart});
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

/// 页面级「撤销」Action：焦点在文本框时禁用，让路给系统文本撤销（而不是
/// 撤销切分编辑器的结构性修改）——语义与 [PageTogglePlayAction] 一致。
class PageUndoAction extends Action<PageUndoIntent> {
  PageUndoAction(this._callback);
  final VoidCallback _callback;

  @override
  bool isEnabled(PageUndoIntent intent) => !isEditableTextFocused();

  @override
  void invoke(PageUndoIntent intent) => _callback();
}

/// 页面级「重做」Action，同上原因用 `isEnabled` 在文本框聚焦时让路
class PageRedoAction extends Action<PageRedoIntent> {
  PageRedoAction(this._callback);
  final VoidCallback _callback;

  @override
  bool isEnabled(PageRedoIntent intent) => !isEditableTextFocused();

  @override
  void invoke(PageRedoIntent intent) => _callback();
}

/// 走带 Action，同样在文本框聚焦时让路（否则打字打不出 j/k/l）
class PageShuttleAction extends Action<PageShuttleIntent> {
  PageShuttleAction(this._callback);
  final ValueChanged<int> _callback;

  @override
  bool isEnabled(PageShuttleIntent intent) => !isEditableTextFocused();

  @override
  void invoke(PageShuttleIntent intent) => _callback(intent.direction);
}

/// 选中导航 Action，同样在文本框聚焦时让路（否则方向键移动不了光标）
class PageSelectAdjacentAction extends Action<PageSelectAdjacentIntent> {
  PageSelectAdjacentAction(this._callback);
  final ValueChanged<int> _callback;

  @override
  bool isEnabled(PageSelectAdjacentIntent intent) => !isEditableTextFocused();

  @override
  void invoke(PageSelectAdjacentIntent intent) => _callback(intent.delta);
}

/// 跳到片头/片尾 Action
class PageSeekEdgeAction extends Action<PageSeekEdgeIntent> {
  PageSeekEdgeAction(this._callback);
  final ValueChanged<bool> _callback;

  @override
  bool isEnabled(PageSeekEdgeIntent intent) => !isEditableTextFocused();

  @override
  void invoke(PageSeekEdgeIntent intent) => _callback(intent.toStart);
}

/// 「快捷键都有哪些」——`?` 或 ⌘/ 叫出速查表。
///
/// 这一堆键（JKL 走带、⇧←→ 粗调、Home/End）实现了，界面上却没有任何地方
/// 说得出来：人在审片台干活时想查，得退回首页翻帮助（2026-09-09 设计走查）。
class PageShortcutsHelpIntent extends Intent {
  const PageShortcutsHelpIntent();
}

class PageShortcutsHelpAction extends Action<PageShortcutsHelpIntent> {
  final VoidCallback _callback;
  PageShortcutsHelpAction(this._callback);

  @override
  void invoke(PageShortcutsHelpIntent intent) => _callback();
}

/// 工具条/滑块区域的按键放行表。
///
/// 页面级快捷键的作用域包住了整个 body（三栏 + 时间线），于是焦点落在时间线
/// 工具条的按钮或缩放滑块上时，方向键会被截成逐帧步进、空格会被截成播放，
/// 这些控件自身的键盘操作（滑块靠方向键微调是 macOS 的标准行为）全部失效。
///
/// 用 [DoNothingAndStopPropagationIntent] 在这一小块区域内把相关按键"吃掉"，
/// 让它们停在这里、由控件自己按系统默认行为处理，而不是继续冒泡到页面级。
const Map<ShortcutActivator, Intent> workbenchControlKeyPassthrough =
    <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.space):
      DoNothingAndStopPropagationIntent(),
  SingleActivator(LogicalKeyboardKey.arrowLeft):
      DoNothingAndStopPropagationIntent(),
  SingleActivator(LogicalKeyboardKey.arrowRight):
      DoNothingAndStopPropagationIntent(),
  SingleActivator(LogicalKeyboardKey.arrowUp):
      DoNothingAndStopPropagationIntent(),
  SingleActivator(LogicalKeyboardKey.arrowDown):
      DoNothingAndStopPropagationIntent(),
  SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true):
      DoNothingAndStopPropagationIntent(),
  SingleActivator(LogicalKeyboardKey.arrowRight, shift: true):
      DoNothingAndStopPropagationIntent(),
  SingleActivator(LogicalKeyboardKey.home):
      DoNothingAndStopPropagationIntent(),
  SingleActivator(LogicalKeyboardKey.end): DoNothingAndStopPropagationIntent(),
};

/// ⇧+方向键的粗调步长（帧）
const int _coarseStepFrames = 10;

/// 快捷键激活表：空格→切换播放，←/→→逐帧步进 ±1 帧，
/// ⌘Z/Ctrl+Z→撤销，⇧⌘Z/Ctrl+⇧Z→重做（macOS 用 ⌘，同时绑 Ctrl 供
/// Windows/Linux 使用，本项目跨平台）
const Map<ShortcutActivator, Intent> workbenchPlaybackShortcuts =
    <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.space): PageTogglePlayIntent(),
  // 回车同样切换播放/暂停。空格是视频工具的通行键位，但双击一段刚播起来时
  // 手往往落在回车上——按下去没反应，用户只会以为播放器卡死了。这个作用域
  // 里回车没有别的含义（对话框是独立路由；焦点在台词框时整套快捷键都放行）。
  SingleActivator(LogicalKeyboardKey.enter): PageTogglePlayIntent(),
  SingleActivator(LogicalKeyboardKey.numpadEnter): PageTogglePlayIntent(),
  SingleActivator(LogicalKeyboardKey.arrowLeft): PageStepFrameIntent(-1),
  SingleActivator(LogicalKeyboardKey.arrowRight): PageStepFrameIntent(1),
  // ⇧+方向键粗调：只有 ±1 帧时跨过一秒要按 30 次
  SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true):
      PageStepFrameIntent(-_coarseStepFrames),
  SingleActivator(LogicalKeyboardKey.arrowRight, shift: true):
      PageStepFrameIntent(_coarseStepFrames),
  // JKL 走带
  SingleActivator(LogicalKeyboardKey.keyJ): PageShuttleIntent(-1),
  SingleActivator(LogicalKeyboardKey.keyK): PageShuttleIntent(0),
  SingleActivator(LogicalKeyboardKey.keyL): PageShuttleIntent(1),
  // ↑↓ 在相邻对象之间移动选中（左右方向键已用于逐帧步进）
  SingleActivator(LogicalKeyboardKey.arrowUp): PageSelectAdjacentIntent(-1),
  SingleActivator(LogicalKeyboardKey.arrowDown): PageSelectAdjacentIntent(1),
  SingleActivator(LogicalKeyboardKey.home): PageSeekEdgeIntent(toStart: true),
  SingleActivator(LogicalKeyboardKey.end): PageSeekEdgeIntent(toStart: false),
  SingleActivator(LogicalKeyboardKey.keyZ, meta: true): PageUndoIntent(),
  SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true):
      PageRedoIntent(),
  SingleActivator(LogicalKeyboardKey.keyZ, control: true): PageUndoIntent(),
  SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true):
      PageRedoIntent(),
  // 「有哪些快捷键」：? 是各家专业工具的通行键位，⌘/ 是 macOS 的说法，
  // 两个都绑上——记不住哪个的人按另一个也能中
  SingleActivator(LogicalKeyboardKey.slash, shift: true):
      PageShortcutsHelpIntent(),
  SingleActivator(LogicalKeyboardKey.question): PageShortcutsHelpIntent(),
  SingleActivator(LogicalKeyboardKey.slash, meta: true):
      PageShortcutsHelpIntent(),
};

/// 快捷键动作表：组装 [PageTogglePlayAction]/[PageStepFrameAction]/
/// [PageUndoAction]/[PageRedoAction]
Map<Type, Action<Intent>> workbenchPlaybackActions({
  required VoidCallback onTogglePlay,
  required ValueChanged<int> onStepFrame,
  required VoidCallback onUndo,
  required VoidCallback onRedo,
  required ValueChanged<int> onShuttle,
  required ValueChanged<bool> onSeekEdge,
  required ValueChanged<int> onSelectAdjacent,
  required VoidCallback onShortcutsHelp,
}) =>
    <Type, Action<Intent>>{
      PageTogglePlayIntent: PageTogglePlayAction(onTogglePlay),
      PageStepFrameIntent: PageStepFrameAction(onStepFrame),
      PageUndoIntent: PageUndoAction(onUndo),
      PageRedoIntent: PageRedoAction(onRedo),
      PageShuttleIntent: PageShuttleAction(onShuttle),
      PageSeekEdgeIntent: PageSeekEdgeAction(onSeekEdge),
      PageSelectAdjacentIntent: PageSelectAdjacentAction(onSelectAdjacent),
      PageShortcutsHelpIntent: PageShortcutsHelpAction(onShortcutsHelp),
    };
