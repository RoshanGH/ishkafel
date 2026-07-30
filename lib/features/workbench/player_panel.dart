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
  State<PlayerPanel> createState() => _PlayerPanelState();
}

class _PlayerPanelState extends State<PlayerPanel> {
  final _focusNode = FocusNode(debugLabel: 'PlayerPanel');
  late StreamSubscription<int> _positionSub;
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
  }

  @override
  void didUpdateWidget(covariant PlayerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.playback, widget.playback)) {
      _positionSub.cancel();
      _positionMs = widget.playback.positionMs;
      _isPlaying = widget.playback.isPlaying;
      _positionSub = widget.playback.positionMsStream.listen((ms) {
        if (!mounted) return;
        setState(() => _positionMs = ms);
      });
    }
  }

  @override
  void dispose() {
    _positionSub.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _togglePlay() async {
    if (_isPlaying) {
      await widget.playback.pause();
    } else {
      await widget.playback.play();
    }
    if (!mounted) return;
    setState(() => _isPlaying = !_isPlaying);
  }

  Future<void> _stepFrame(int frames) => widget.playback.stepFrames(frames, widget.fps);

  Future<void> _seekToStart() => widget.playback.seekMs(0);

  Future<void> _seekToEnd() => widget.playback.seekMs(widget.durationMs);

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
            color: Colors.black,
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
