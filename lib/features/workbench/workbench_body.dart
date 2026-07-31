import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../core/editing/segmentation_editor_controller.dart';
import '../../core/playback/playback_controller.dart';
import 'inspector_panel.dart';
import 'player_panel.dart';
import 'timeline/timeline_geometry.dart';
import 'timeline/timeline_painter.dart';
import 'timeline/timeline_view.dart';
import 'timeline_media_builder.dart';
import 'unit_list_panel.dart';
import 'workbench_shortcuts.dart';

/// 审片台主体：三栏（单元列表/播放器/检查器）+ 时间线，从 `workbench_page.dart`
/// 拆出的独立 StatefulWidget。
///
/// 拆分理由：[TimelineGeometry]/缩放倍数/时间线视口宽度这几项状态是"时间线
/// 展示区"的局部展示细节（缩放交互、resize 重新 clamp），页面级 State
/// （`WorkbenchPage`）自身的职责（装配编辑器/播放器、确认流转、离开确认）
/// 完全不需要读取它们——把它们留在页面级 State 里只是历史遗留的"放在一起"，
/// 搬到这里后各自的状态归属更清楚：本 Widget 自己的 State 持有时间线专属
/// 的展示状态；`WorkbenchPage` 只需要转发 [editor]/[playback]/[videoWidget]/
/// [media]/[playhead] 这几个"跨区域共享"的值。同理，页面级播放快捷键
/// （空格/←/→）转发到 [PlayerPanel] 的 [GlobalKey] 只在本组件内部使用，
/// 也一并搬入，`WorkbenchPage` 不再需要关心它。
class WorkbenchBody extends StatefulWidget {
  final SegmentationEditorController editor;
  final PlaybackController playback;
  final Widget? videoWidget;
  final TimelineMedia? media;
  /// 播放位置（只驱动时间线播放头，不参与页面重建，见 workbench_page.dart）
  final ValueListenable<int> playhead;

  /// 抽帧/波形就绪状态，透传给时间线画占位
  final TimelineMediaStatus mediaStatus;

  /// 只读回看模式（评审 Important 1）：picking/exported 状态下已确认的
  /// 切分结构不允许再被静默改写，下发到 [TimelineView]/[InspectorPanel]。
  final bool readOnly;

  const WorkbenchBody({
    super.key,
    required this.editor,
    required this.playback,
    this.videoWidget,
    this.media,
    required this.playhead,
    this.mediaStatus = TimelineMediaStatus.ready,
    this.readOnly = false,
  });

  @override
  State<WorkbenchBody> createState() => _WorkbenchBodyState();
}

class _WorkbenchBodyState extends State<WorkbenchBody> {
  /// 转发页面级快捷键到 PlayerPanel 内部同一份播放状态（避免另起一份
  /// `_isPlaying` 导致图标显示不同步）
  final _playerPanelKey = GlobalKey<PlayerPanelState>();

  TimelineGeometry? _geometry;
  double _zoomLevel = 1.0;
  double _timelineViewportWidth = 0;

  /// 页面级快捷键转发：与 PlayerPanel 内部按钮走同一份播放状态
  void _togglePlaybackFromShortcut() =>
      _playerPanelKey.currentState?.togglePlay();

  void _stepPlaybackFromShortcut(int frames) =>
      _playerPanelKey.currentState?.stepFrame(frames);

  void _onZoomChanged(double value) {
    final geometry = _geometry;
    if (geometry == null || _timelineViewportWidth <= 0) return;
    final factor = value / _zoomLevel;
    setState(() {
      _zoomLevel = value;
      _geometry = geometry.zoomAt(_timelineViewportWidth / 2, factor,
          viewportWidthPx: _timelineViewportWidth);
    });
  }

  /// 页面级全局快捷键作用域：包裹三栏 + 时间线（不含顶栏/底部栏，那两处的
  /// 按钮本就该响应系统默认的空格/回车激活）。焦点无论落在单元列表、检查器
  /// 的步进按钮还是时间线上，空格/←/→都会被这里截获转发给播放器；焦点若
  /// 落在台词输入框，`workbench_shortcuts.dart` 里 Action 的 `isEnabled`
  /// 会返回 false，按键继续正常走文本编辑逻辑（详见该文件文档）。
  @override
  Widget build(BuildContext context) {
    final editor = widget.editor;
    final playback = widget.playback;
    return Shortcuts(
      shortcuts: workbenchPlaybackShortcuts,
      child: Actions(
        actions: workbenchPlaybackActions(
          onTogglePlay: _togglePlaybackFromShortcut,
          onStepFrame: _stepPlaybackFromShortcut,
          onUndo: editor.undo,
          onRedo: editor.redo,
          onShuttle: _shuttle,
          onSeekEdge: (toStart) => playback
              .seekMs(toStart ? 0 : editor.durationMs),
        ),
        child: Column(
          children: [
            Expanded(
              flex: 3,
              child: Row(
                children: [
                  SizedBox(
                    width: 320,
                    child: UnitListPanel(
                      controller: editor,
                      onUnitTap: (unit) => playback.seekMs(unit.startMs),
                    ),
                  ),
                  const VerticalDivider(width: 1, color: AppColors.border),
                  Expanded(
                    child: PlayerPanel(
                      key: _playerPanelKey,
                      playback: playback,
                      videoWidget: widget.videoWidget,
                      durationMs: editor.durationMs,
                      fps: editor.fps,
                    ),
                  ),
                  const VerticalDivider(width: 1, color: AppColors.border),
                  SizedBox(
                    width: 300,
                    child: InspectorPanel(
                      controller: editor,
                      fps: editor.fps,
                      onSplitAtPlayhead: () =>
                          _splitAtPlayhead(context, editor, playback),
                      readOnly: widget.readOnly,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: AppColors.border),
            Expanded(
              flex: 2,
              child: _buildTimelineArea(editor, playback),
            ),
          ],
        ),
      ),
    );
  }

  /// JKL 走带：L 正向播放、K 停、J 反向。
  ///
  /// 真正的 JKL 是变速走带（连按 J/L 加速到 2×/4×），需要播放器暴露倍速
  /// 控制；[PlaybackController] 目前没有这个能力，所以 J 退化为「暂停并
  /// 逐帧倒退」——保证按下去有确定的、符合方向直觉的反馈，而不是无反应。
  /// 变速走带已记入待办。
  void _shuttle(int direction) {
    final playback = widget.playback;
    if (direction > 0) {
      playback.play();
      return;
    }
    playback.pause();
    if (direction < 0) {
      playback.stepFrames(-1, widget.editor.fps);
    }
  }

  /// 「在游标处拆分」：播放头不落在所选单元/镜头范围内时 [SegmentationEditorController.
  /// splitSelectedAt] 会返回 false（纯函数拒绝了非法拆分点），此前这里直接
  /// 丢弃返回值，用户点击按钮却毫无反应，体验上像是按钮失灵。补一条
  /// SnackBar 提示，让"为什么没有拆分"这件事对用户可见（Minor）。
  void _splitAtPlayhead(BuildContext context, SegmentationEditorController editor,
      PlaybackController playback) {
    final ok = editor.splitSelectedAt(playback.positionMs);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('播放头不在所选范围内，无法在此处拆分')),
      );
    }
  }

  Widget _buildTimelineArea(
      SegmentationEditorController editor, PlaybackController playback) {
    return Container(
      color: AppColors.surface,
      child: Column(
        children: [
          // 工具条按钮的禁用态取自编辑器（canUndo/canRedo/selection），必须
          // 自己监听：页面级 setState 已被移除（播放时每秒 30 次重建整页的
          // 性能问题），不能再指望父级顺手帮它重建
          AnimatedBuilder(
            animation: editor,
            builder: (context, _) => _buildTimelineToolbar(editor),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                if (width != _timelineViewportWidth) {
                  _timelineViewportWidth = width;
                  final geometry = _geometry;
                  // 窗口 resize：视口宽度变化时至少重新 clamp scrollPx，
                  // 避免旧滚动值在新（更窄）视口下越界露出空白
                  _geometry = geometry == null
                      ? TimelineGeometry.fit(
                          durationMs: editor.durationMs, viewportWidthPx: width)
                      : geometry.scrolledBy(0, viewportWidthPx: width);
                }
                return TimelineView(
                  controller: editor,
                  geometry: _geometry!,
                  media: widget.media,
                  playhead: widget.playhead,
                  mediaStatus: widget.mediaStatus,
                  onSeek: (ms) => playback.seekMs(ms),
                  onGeometryChanged: (g) => setState(() => _geometry = g),
                  readOnly: widget.readOnly,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimelineToolbar(SegmentationEditorController editor) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Row(
        children: [
          _undoRedoButton(
            key: const Key('timeline-undo-btn'),
            icon: Icons.undo,
            enabled: editor.canUndo,
            onTap: editor.undo,
          ),
          _undoRedoButton(
            key: const Key('timeline-redo-btn'),
            icon: Icons.redo,
            enabled: editor.canRedo,
            onTap: editor.redo,
          ),
          const SizedBox(width: AppSpacing.sm),
          const _ToolbarDivider(),
          const SizedBox(width: AppSpacing.sm),
          // 拆分/合并在时间线上也给入口：此前只能从右侧检查器触发，而用户
          // 调整切分时视线与鼠标都在时间线上，来回横跨整个窗口很别扭
          _undoRedoButton(
            key: const Key('timeline-split-btn'),
            icon: Icons.content_cut,
            tooltip: '在游标处拆分所选（台词语义单元或视觉镜头）',
            enabled: !widget.readOnly && editor.selection != null,
            onTap: () => _splitAtPlayhead(context, editor, widget.playback),
          ),
          _undoRedoButton(
            key: const Key('timeline-merge-btn'),
            icon: Icons.merge_type,
            tooltip: '把所选并入前一个',
            enabled: !widget.readOnly && editor.selection != null,
            onTap: editor.mergeSelectedWithPrevious,
          ),
          const SizedBox(width: AppSpacing.sm),
          const _ToolbarDivider(),
          const SizedBox(width: AppSpacing.sm),
          const Icon(Icons.zoom_out, color: AppColors.textTertiary, size: 16),
          Expanded(
            child: Slider(
              key: const Key('timeline-zoom-slider'),
              value: _zoomLevel,
              min: 1,
              max: 20,
              onChanged: _onZoomChanged,
            ),
          ),
          const Icon(Icons.zoom_in, color: AppColors.textTertiary, size: 16),
        ],
      ),
    );
  }

  /// 时间线工具条的撤销/重做按钮：对标剪映的可发现性，与 ⌘Z/⇧⌘Z 快捷键
  /// 是同一份撤销栈；[enabled] 为 false 时降透明度且不响应点击。
  Widget _undoRedoButton({
    required Key key,
    required IconData icon,
    required bool enabled,
    required VoidCallback onTap,
    String? tooltip,
  }) {
    return IconButton(
      key: key,
      onPressed: enabled ? onTap : null,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      icon: Icon(
        icon,
        size: 16,
        color: enabled
            ? AppColors.textPrimary
            : AppColors.textTertiary.withValues(alpha: 0.35),
      ),
    );
  }
}

/// 工具条分组分隔线：把撤销/编辑/缩放三组操作在视觉上分开
class _ToolbarDivider extends StatelessWidget {
  const _ToolbarDivider();

  @override
  Widget build(BuildContext context) => Container(
        width: AppStroke.hairline,
        height: 16,
        color: AppColors.border,
      );
}
