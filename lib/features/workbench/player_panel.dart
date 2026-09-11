import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_typography.dart';
import '../../core/playback/playback_controller.dart';
import '../../core/time/timecode.dart' show formatTimecode, timecodeLegend;

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
  /// 播放位置。用 ValueNotifier 而不是 State 字段：它每秒变化 30 次，唯一的
  /// 消费者是 transport 上那行时间码文字，走 setState 会连带重建整个播放器
  /// 面板（含视频区域），实测每 tick 白付约 2.2ms。
  final ValueNotifier<int> _positionMs = ValueNotifier<int>(0);
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _positionMs.value = widget.playback.positionMs;
    _isPlaying = widget.playback.isPlaying;
    _positionSub = widget.playback.positionMsStream.listen((ms) {
      if (!mounted) return;
      _positionMs.value = ms;
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
      _positionMs.value = widget.playback.positionMs;
      _isPlaying = widget.playback.isPlaying;
      _positionSub = widget.playback.positionMsStream.listen((ms) {
        if (!mounted) return;
        _positionMs.value = ms;
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
    _positionMs.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// 切换播放/暂停：翻转决策读取 [PlaybackController.isPlaying] 这一真实
  /// 状态（而不是本地镜像字段 [_isPlaying]），翻转后的显示状态同样在 await
  /// 完成后重新读取该真实状态——快速连按两次时，本地镜像字段的 setState
  /// 更新会被推迟到第一次 await 完成之后的微任务里，若决策仍依赖本地字段，
  /// 两次调用会都读到"翻转前"的旧值、都判定为同一个操作（例如都调用
  /// play()），第二次点击（用户意图是反向操作）就被悄悄吞掉（评审
  /// Minor E）。真实播放器（如 media_kit）的 isPlaying 在 play()/pause()
  /// 内部通常会同步或近乎同步地更新，能及时反映"上一次点击已经生效"这一
  /// 事实，让第二次点击基于最新真实状态正确判定为反向操作。订阅
  /// [PlaybackController.playingStream]（见 [initState]）进一步保证外部
  /// 状态变化也能同步图标。
  Future<void> _togglePlay() async {
    if (widget.playback.isPlaying) {
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
            // 中栏是「剧场」：比两侧工作栏再沉一级，预览从背景里凹出来。
            // 用全局背景色的话，画面和它周围那片黑是同一个平面，
            // 9:16 素材两侧的留白就读成「没做完」而不是「舞台」
            color: AppColors.stageWell,
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
      child: Padding(
        // 画面不贴着上下边缘：舞台要有天地，紧贴着会读成「被裁掉了」
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: AspectRatio(
          aspectRatio: 9 / 16,
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.stageBackground,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              // 一圈边 + 一层落影：把画面从舞台底色里托起来。
              // 少了这两样，深色画面（夜景、黑场）和背景连成一片，
              // 人看不出画幅到哪儿为止。用 [AppColors.stageEdge] 而不是
              // 普通 border——后者在「黑画面压黑舞台」上根本看不见
              border: Border.all(color: AppColors.stageEdge),
              boxShadow: const [
                BoxShadow(
                    color: Color(0x99000000),
                    blurRadius: 24,
                    offset: Offset(0, 6)),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: widget.videoWidget ??
                const Center(
                  child: Icon(Icons.movie_outlined,
                      color: AppColors.textTertiary, size: 40),
                ),
          ),
        ),
      ),
    );
  }

  Widget _buildTransport() {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm, vertical: AppSpacing.sm),
      // **控制条属于剧场，不是又一块面板**。原来用 surfaceRaised，
      // 在几乎全黑的舞台底上是一条突兀的亮横条（2026-09-10 走查）。
      // 现在贴着舞台底色，只用一条细线把它和画面分开
      decoration: const BoxDecoration(
        color: AppColors.stageWell,
        border: Border(top: BorderSide(color: AppColors.topHighlight)),
      ),
      // 窄栏（挑素材时中栏会被压到 280）下按钮和时间码并排放不下。
      // **不能靠横向滚动兜底**：滚动只是把时间码推到可视区外，人看到的是
      // 「00:00.00 / 01:1」——一个被咬掉一半的数字，而且没有任何东西告诉他
      // 还能滚（2026-09-09 设计走查真机截图）。挤不下就换行，时间码永远完整
      child: LayoutBuilder(builder: (context, box) {
        final clock = ValueListenableBuilder<int>(
          valueListenable: _positionMs,
          // 这两个数是**成片**位置，而 `.28` 是帧号不是小数。
          // 播放器这一行摆不下一句说明，那就挂在悬停上——属性面板里
          // 有完整图例（见 inspectorTimecodeLegend）
          builder: (context, posMs, _) => Tooltip(
            message: '成片位置 / 成片总长\n${timecodeLegend(widget.fps)}',
            child: Text(
              '${formatTimecode(posMs, widget.fps)} / '
              '${formatTimecode(widget.durationMs, widget.fps)}',
              key: const Key('player-clock'),
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: AppFontSize.body,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        );
        // 五个键并排要 ~250px。再窄就先舍「跳到片头/片尾」——那两个
        // 有快捷键也有时间线可以点，而逐帧和播放没有别的入口
        final buttons = Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: _transportButtons(compact: box.maxWidth < 260),
        );
        // **用 Wrap 而不是一个宽度阈值**：按钮组的真实宽度取决于 IconButton
        // 的最小命中区和时间码的位数，写死一个阈值总会在某个宽度上判错——
        // 判小了这一行就溢出（测试里 422px 溢出 31px）。Wrap 自己量，
        // 放得下并排、放不下换行，两种情况都不会把时间码咬掉
        return Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.xs,
          children: [buttons, clock],
        );
      }),
    );
  }

  List<Widget> _transportButtons({bool compact = false}) {
    return [
          if (!compact)
            _transportButton(
              key: const Key('player-seek-start'),
              icon: Icons.skip_previous,
              tooltip: '回到片头　Home',
              onTap: _seekToStart,
            ),
          _transportButton(
            key: const Key('player-step-back'),
            icon: Icons.chevron_left,
            tooltip: '后退一帧　←（⇧← 一次 10 帧）',
            onTap: () => _stepFrame(-1),
          ),
          const SizedBox(width: 4),
          _transportButton(
            key: const Key('player-toggle-play'),
            icon: _isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill,
            tooltip: _isPlaying ? '暂停　空格' : '播放　空格',
            size: 30,
            onTap: _togglePlay,
          ),
          const SizedBox(width: 4),
          _transportButton(
            key: const Key('player-step-forward'),
            icon: Icons.chevron_right,
            tooltip: '前进一帧　→（⇧→ 一次 10 帧）',
            onTap: () => _stepFrame(1),
          ),
          if (!compact)
            _transportButton(
              key: const Key('player-seek-end'),
              icon: Icons.skip_next,
              tooltip: '跳到片尾　End',
              onTap: _seekToEnd,
            ),
    ];
  }

  Widget _transportButton({
    required Key key,
    required IconData icon,
    required VoidCallback onTap,
    required String tooltip,
    double size = 22,
  }) {
    return IconButton(
      key: key,
      // **tooltip 里带上快捷键**：这五个键全是纯图标，人既猜不出
      // 「⏮」是回片头还是上一镜，也无从知道有键盘可用
      tooltip: tooltip,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      constraints: const BoxConstraints(),
      icon: Icon(icon, color: AppColors.textPrimary, size: size),
    );
  }
}
