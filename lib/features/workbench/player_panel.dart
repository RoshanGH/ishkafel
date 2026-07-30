import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme/app_colors.dart';
import '../../core/playback/playback_controller.dart';
import 'inspector_panel.dart' show formatTimecode;

/// 播放空格切换意图（Shortcuts→Actions 转发用）
class _TogglePlayIntent extends Intent {
  const _TogglePlayIntent();
}

/// 逐帧步进意图：[frames] 为正前进、为负后退
class _StepFrameIntent extends Intent {
  final int frames;
  const _StepFrameIntent(this.frames);
}

/// 播放器面板：9:16 舞台居中 + transport 控制条
///
/// 只负责播放/暂停/逐帧/跳转的 UI 与快捷键转发，具体播放能力经构造注入
/// [PlaybackController]（测试传 [FakePlaybackController]，生产传
/// `MediaKitPlaybackController`）。当前播放位置从
/// [PlaybackController.positionMsStream] 订阅而来，不由外部逐帧传入。
class PlayerPanel extends StatefulWidget {
  final PlaybackController playback;
  final Widget? videoWidget;
  final int durationMs;
  final double fps;

  const PlayerPanel({
    super.key,
    required this.playback,
    this.videoWidget,
    required this.durationMs,
    required this.fps,
  });

  @override
  State<PlayerPanel> createState() => PlayerPanelState();
}

/// 公开 State 类型（而非常见的 `_PlayerPanelState`私有类）：审片台页面级
/// 全局快捷键（见 `workbench_page.dart`）需要通过 `GlobalKey<PlayerPanelState>`
/// 转发到 [togglePlay]/[stepFrame]，与本面板内部按钮走同一份播放/暂停状态，
/// 避免页面级与面板内部各自维护一份 `_isPlaying` 导致图标显示不同步。
class PlayerPanelState extends State<PlayerPanel> {
  final _focusNode = FocusNode(debugLabel: 'PlayerPanel');
  late StreamSubscription<int> _positionSub;
  late StreamSubscription<bool> _playingSub;
  int _positionMs = 0;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _positionMs = widget.playback.positionMs;
    _isPlaying = widget.playback.isPlaying;
    _positionSub = widget.playback.positionMsStream.listen((ms) {
      if (!mounted) return;
      setState(() => _positionMs = ms);
    });
    // 订阅播放状态流：无论状态变化来自本面板按钮、页面级快捷键，还是外部
    // 原因（如播放到片尾自动暂停），图标都只有一份真源（真实 isPlaying），
    // 不再靠本地变量盲目翻转（评审 Important 2）。
    _playingSub = widget.playback.playingStream.listen((playing) {
      if (!mounted) return;
      setState(() => _isPlaying = playing);
    });
  }

  @override
  void didUpdateWidget(covariant PlayerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.playback, widget.playback)) {
      _positionSub.cancel();
      _playingSub.cancel();
      _positionMs = widget.playback.positionMs;
      _isPlaying = widget.playback.isPlaying;
      _positionSub = widget.playback.positionMsStream.listen((ms) {
        if (!mounted) return;
        setState(() => _positionMs = ms);
      });
      _playingSub = widget.playback.playingStream.listen((playing) {
        if (!mounted) return;
        setState(() => _isPlaying = playing);
      });
    }
  }

  @override
  void dispose() {
    _positionSub.cancel();
    _playingSub.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  /// 切换播放/暂停：翻转决策仍取自"翻转前"的 [_isPlaying]（决定该调用
  /// play() 还是 pause()），但翻转后的显示状态改为 await 完成后重新读取
  /// [PlaybackController.isPlaying] 这一真实状态，而不是对本地变量取反
  /// ——快速连按两次时，两次调用都可能基于翻转前的旧状态判定为同一个
  /// 操作（例如都调用 play()），若仍对本地变量取反两次，图标会错误地翻回
  /// 与真实状态相反的一面（评审 Important 2）。订阅 [PlaybackController.
  /// playingStream]（见 [initState]）进一步保证外部状态变化也能同步图标。
  Future<void> _togglePlay() async {
    if (_isPlaying) {
      await widget.playback.pause();
    } else {
      await widget.playback.play();
    }
    if (!mounted) return;
    setState(() => _isPlaying = widget.playback.isPlaying);
  }

  Future<void> _stepFrame(int frames) => widget.playback.stepFrames(frames, widget.fps);

  Future<void> _seekToStart() => widget.playback.seekMs(0);

  Future<void> _seekToEnd() => widget.playback.seekMs(widget.durationMs);

  /// 供外部（审片台页面级全局快捷键）转发调用：与本面板内部按钮/快捷键
  /// 完全一致的播放切换逻辑，确保 `_isPlaying` 显示状态只有一份真源。
  Future<void> togglePlay() => _togglePlay();

  /// 供外部（审片台页面级全局快捷键）转发调用的逐帧步进。
  Future<void> stepFrame(int frames) => _stepFrame(frames);

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.space): _TogglePlayIntent(),
        SingleActivator(LogicalKeyboardKey.arrowLeft): _StepFrameIntent(-1),
        SingleActivator(LogicalKeyboardKey.arrowRight): _StepFrameIntent(1),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _TogglePlayIntent: CallbackAction<_TogglePlayIntent>(
              onInvoke: (_) => _togglePlay()),
          _StepFrameIntent: CallbackAction<_StepFrameIntent>(
              onInvoke: (intent) => _stepFrame(intent.frames)),
        },
        child: Focus(
          focusNode: _focusNode,
          autofocus: true,
          child: Container(
            color: AppColors.background,
            child: Column(
              children: [
                Expanded(child: _buildStage()),
                _buildTransport(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStage() {
    return Center(
      child: AspectRatio(
        aspectRatio: 9 / 16,
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.stageBackground,
            borderRadius: BorderRadius.circular(12),
          ),
          clipBehavior: Clip.antiAlias,
          child: widget.videoWidget ??
              const Center(
                child: Icon(Icons.movie_outlined,
                    color: AppColors.textTertiary, size: 40),
              ),
        ),
      ),
    );
  }

  Widget _buildTransport() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      color: AppColors.surfaceRaised,
      // 窄栏（如三栏挤压后的播放器列）下 transport 内容可能超出可视宽度，
      // 用水平滚动兜底，避免 RenderFlex 溢出报错，不裁掉任何控件
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _transportButton(
            key: const Key('player-seek-start'),
            icon: Icons.skip_previous,
            onTap: _seekToStart,
          ),
          _transportButton(
            key: const Key('player-step-back'),
            icon: Icons.chevron_left,
            onTap: () => _stepFrame(-1),
          ),
          const SizedBox(width: 4),
          _transportButton(
            key: const Key('player-toggle-play'),
            icon: _isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill,
            size: 30,
            onTap: _togglePlay,
          ),
          const SizedBox(width: 4),
          _transportButton(
            key: const Key('player-step-forward'),
            icon: Icons.chevron_right,
            onTap: () => _stepFrame(1),
          ),
          _transportButton(
            key: const Key('player-seek-end'),
            icon: Icons.skip_next,
            onTap: _seekToEnd,
          ),
          const SizedBox(width: 12),
          Text(
            '${formatTimecode(_positionMs, widget.fps)} / ${formatTimecode(widget.durationMs, widget.fps)}',
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
        ),
      ),
    );
  }

  Widget _transportButton({
    required Key key,
    required IconData icon,
    required VoidCallback onTap,
    double size = 22,
  }) {
    return IconButton(
      key: key,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      constraints: const BoxConstraints(),
      icon: Icon(icon, color: AppColors.textPrimary, size: size),
    );
  }
}
