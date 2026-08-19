import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/log/app_log.dart';
import '../../core/models/renew_task.dart';
import '../../core/script/script_doc.dart';
import '../../core/script/script_transcriber.dart';
import '../../core/storage/task_lock.dart';
import '../../core/storage/task_repository.dart';
import '../settings/settings_providers.dart';
import '../tasks/new_task_wizard/wizard_providers.dart';
import '../tasks/task_list_controller.dart';
import 'director_providers.dart';
import 'line_inspector.dart';
import 'script_panel.dart';
import 'start_guide.dart';

/// 编导台——「脚本成片」的工作页（对仗审片台）。
///
/// 三栏：左 = 脚本（唯一的真相 + 总览导航）；中 = 预览（成片的影子）；
/// 右 = 当前行的工作台（聚焦深工）。见 docs/2026-08-19 设计稿。
class DirectorPage extends ConsumerStatefulWidget {
  final RenewTask task;

  const DirectorPage({super.key, required this.task});

  @override
  ConsumerState<DirectorPage> createState() => _DirectorPageState();
}

/// 「从视频提取脚本」此刻的状态：没在跑 / 跑到哪一步 / 挂在哪
sealed class _ExtractState {
  const _ExtractState();
}

class _ExtractRunning extends _ExtractState {
  final ScriptTranscribeStage stage;
  const _ExtractRunning(this.stage);
}

class _ExtractFailed extends _ExtractState {
  final String message;
  const _ExtractFailed(this.message);
}

class _DirectorPageState extends ConsumerState<DirectorPage> {
  late RenewTask _task = widget.task;
  late ScriptDoc _doc = widget.task.script ?? ScriptDoc.empty();
  int _selected = 0;

  /// 刚插入的行：让它的输入框自动聚焦（回车后手不离键盘）
  String? _autofocusLineId;

  Timer? _autosave;
  bool _saving = false;
  TaskLockFile? _lock;
  Timer? _lockHeartbeat;
  String? _blockedBy;

  _ExtractState? _extract;

  /// 用户在空脚本上点了「直接开始写」：起步引导让位给预览
  bool _guideDismissed = false;

  /// initState 里取好：dispose 阶段还要落一次盘，那时不能再碰 ref
  late final TaskRepository _repo;

  @override
  void initState() {
    super.initState();
    _repo = ref.read(taskRepositoryProvider);
    _acquireLock();
  }

  static String get _holder => '人（编导台）';

  /// 与工作台/审核页同一套会话级互斥：谁先进谁处理
  void _acquireLock() {
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) return;
    final lock = TaskLockFile(dataDir: dataDir, taskId: _task.id);
    if (!lock.acquire(_holder)) {
      _blockedBy = lock.read()?.holder ?? '别人';
      return;
    }
    _lock = lock;
    // 心跳让锁活着：写脚本可能一坐半小时，超时失效等于没锁
    _lockHeartbeat = Timer.periodic(
        const Duration(seconds: 20), (_) => lock.heartbeat(_holder));
  }

  /// 抢锁是破坏性的（对方之后的保存会被拒绝），与审核页同一套确认规矩
  Future<void> _forceTakeover() async {
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前环境没有数据目录，无法接管')));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('强制接管这个任务？'),
        content: Text('「${_blockedBy ?? '对方'}」之后的保存会被拒绝，'
            '它未落盘的改动可能丢失。确定要接管吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('接管')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final lock = TaskLockFile(dataDir: dataDir, taskId: _task.id);
    lock.forceTakeover(_holder);
    setState(() => _blockedBy = null);
    _lock = lock;
    _lockHeartbeat = Timer.periodic(
        const Duration(seconds: 20), (_) => lock.heartbeat(_holder));
  }

  @override
  void dispose() {
    _autosave?.cancel();
    _flushNow();
    _lockHeartbeat?.cancel();
    _lock?.release(_holder);
    super.dispose();
  }

  /// 改动随手落库（800ms 防抖）——写作软件没有「保存」这回事
  void _mutate(ScriptDoc Function(ScriptDoc) f) {
    setState(() {
      _doc = f(_doc);
      _saving = true;
    });
    _autosave?.cancel();
    _autosave = Timer(const Duration(milliseconds: 800), _flushNow);
  }

  void _flushNow() {
    _autosave?.cancel();
    _task = _task.copyWith(script: _doc, updatedAt: DateTime.now());
    unawaited(_repo.save(_task).then((_) {
      if (mounted) setState(() => _saving = false);
    }).catchError((Object e) {
      AppLog.warn('脚本落库失败（taskId=${_task.id}）：$e');
    }));
  }

  bool get _scriptIsPristine =>
      _doc.lines.length == 1 && _doc.lines.single.text.trim().isEmpty;

  /// 「从视频提取脚本」全流程：选文件 → （非空时确认覆盖）→ 三步提取 →
  /// 覆盖填充。失败给原因和重试，不静默。
  Future<void> _extractFromVideo() async {
    final transcriber = ref.read(scriptTranscriberProvider);
    if (transcriber == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('尚未配置 AI 服务（语音识别与语义分行），无法从视频提取脚本。')));
      return;
    }
    if (!_scriptIsPristine) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('用提取结果替换当前脚本？'),
          content: Text(
              '当前脚本已有 ${_doc.lines.length} 行，提取出的台词会整体替换它们，'
              '此操作无法撤销。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('替换')),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    if (!mounted) return;
    final path = await ref.read(videoFilePickerProvider)();
    if (path == null || !mounted) return;

    setState(() =>
        _extract = const _ExtractRunning(ScriptTranscribeStage.extractingAudio));
    try {
      final lines = await transcriber.extract(path, onStage: (stage) {
        if (mounted) setState(() => _extract = _ExtractRunning(stage));
      });
      if (!mounted) return;
      setState(() {
        _doc = ScriptDoc(lines);
        _selected = 0;
        _extract = null;
        _guideDismissed = true;
      });
      _flushNow();
    } on ScriptTranscribeException catch (e) {
      AppLog.warn('脚本提取失败（$path）：${e.cause ?? e.message}');
      if (mounted) setState(() => _extract = _ExtractFailed(e.message));
    } catch (e) {
      AppLog.warn('脚本提取失败（$path）：$e');
      if (mounted) {
        setState(() =>
            _extract = const _ExtractFailed('提取失败，请稍后重试。'));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_blockedBy != null) return _blockedView();
    final extracting = _extract is _ExtractRunning;
    // 起步引导激活时右栏收敛：一边问「从哪里开始」、一边摆开行工作台，
    // 两套话语打架（真机截图核对时发现）
    final showGuide =
        _scriptIsPristine && !_guideDismissed && _extract == null;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(children: [
        _topBar(),
        const Divider(height: 1, thickness: 1, color: AppColors.border),
        Expanded(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // 左：脚本——唯一的真相
            Container(
              width: 360,
              color: AppColors.surface,
              child: Column(children: [
                if (_extract != null) _extractBanner(),
                Expanded(
                  child: IgnorePointer(
                    ignoring: extracting,
                    child: ScriptPanel(
                      doc: _doc,
                      selected: _selected,
                      autofocusLineId: _autofocusLineId,
                      onSelect: (i) => setState(() => _selected = i),
                      onInsertAfter: (i) {
                        _mutate((d) => d.insertAfter(i));
                        setState(() {
                          _selected = i + 1;
                          _autofocusLineId = _doc.lines[i + 1].id;
                          _guideDismissed = true;
                        });
                      },
                      onRemove: (i) {
                        _mutate((d) => d.removeAt(i));
                        if (_selected >= _doc.lines.length) {
                          setState(
                              () => _selected = _doc.lines.length - 1);
                        }
                      },
                      onMove: (from, to) {
                        _mutate((d) => d.move(from, to));
                        setState(() => _selected = to);
                      },
                      onTextChanged: (i, text) =>
                          _mutate((d) => d.updateText(i, text)),
                    ),
                  ),
                ),
              ]),
            ),
            const VerticalDivider(
                width: 1, thickness: 1, color: AppColors.border),
            // 中：预览（M4 点亮）；空脚本时先当起步引导的舞台
            Expanded(
              child: showGuide ? _startGuide() : _previewStage(),
            ),
            const VerticalDivider(
                width: 1, thickness: 1, color: AppColors.border),
            // 右：当前行工作台（M2 配音 / M3 镜头逐步点亮）
            Container(
              width: 340,
              color: AppColors.surface,
              child: (!showGuide &&
                      _selected >= 0 &&
                      _selected < _doc.lines.length)
                  ? LineInspector(
                      index: _selected,
                      line: _doc.lines[_selected],
                      onManualMsChanged: (ms) =>
                          _mutate((d) => d.setManualMs(_selected, ms)),
                    )
                  : const SizedBox.shrink(),
            ),
          ]),
        ),
      ]),
    );
  }

  /// 顶栏：返回 + 身份（#编号 · 名字 · 模块徽标）+ 保存状态。
  /// 自动保存要**说出来**——用户不问「存了没」是因为界面一直在回答
  Widget _topBar() => Container(
        height: 48,
        color: AppColors.surface,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        child: Row(children: [
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back_ios_new,
                size: 15, color: AppColors.textSecondary),
            tooltip: '返回任务列表',
          ),
          const SizedBox(width: AppSpacing.xs),
          if (_task.seq != null)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Text('#${_task.seq}',
                  style: const TextStyle(
                      fontSize: AppFontSize.emphasis,
                      color: AppColors.textTertiary,
                      fontFeatures: [FontFeature.tabularFigures()])),
            ),
          Flexible(
            child: Text(_task.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: AppFontSize.emphasis,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary)),
          ),
          const SizedBox(width: AppSpacing.sm),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.accentBlue.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
            ),
            child: const Text('编导台',
                style: TextStyle(
                    fontSize: AppFontSize.micro,
                    fontWeight: FontWeight.w600,
                    color: AppColors.accentBlueLight)),
          ),
          const Spacer(),
          Text(_saving ? '保存中…' : '更改已自动保存',
              style: const TextStyle(
                  fontSize: AppFontSize.caption,
                  color: AppColors.textTertiary)),
          const SizedBox(width: AppSpacing.sm),
          _extractButton(),
          const SizedBox(width: AppSpacing.xs),
        ]),
      );

  Widget _extractButton() {
    final available = ref.watch(scriptTranscriberProvider) != null;
    final running = _extract is _ExtractRunning;
    final button = OutlinedButton.icon(
      key: const ValueKey('director-extract-script'),
      onPressed: available && !running ? _extractFromVideo : null,
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.textPrimary,
        side: const BorderSide(color: AppColors.border),
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: 6),
        textStyle: const TextStyle(fontSize: AppFontSize.body),
      ),
      icon: const Icon(Icons.subtitles_outlined, size: 14),
      label: const Text('从视频提取脚本'),
    );
    if (available) return button;
    // 禁用要说明原因——点不动又不解释的按钮等于坏了
    return Tooltip(
        message: '尚未配置 AI 服务（语音识别与语义分行），无法提取',
        child: button);
  }

  /// 提取进行中/失败的交代条：等待有进度，失败有原因和重试
  Widget _extractBanner() {
    final state = _extract;
    if (state is _ExtractRunning) {
      return Container(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: AppColors.accentBlue)),
            const SizedBox(width: AppSpacing.sm),
            Text(state.stage.label,
                style: const TextStyle(
                    fontSize: AppFontSize.body,
                    color: AppColors.textSecondary)),
          ]),
          const SizedBox(height: AppSpacing.sm),
          const LinearProgressIndicator(
              minHeight: 2,
              color: AppColors.accentBlue,
              backgroundColor: AppColors.surfaceCard),
        ]),
      );
    }
    if (state is _ExtractFailed) {
      return Container(
        margin: const EdgeInsets.fromLTRB(
            AppSpacing.sm, AppSpacing.sm, AppSpacing.sm, 0),
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.red.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(state.message,
              style: const TextStyle(
                  fontSize: AppFontSize.body,
                  color: AppColors.red,
                  height: 1.4)),
          const SizedBox(height: AppSpacing.xs),
          Row(children: [
            TextButton(
                onPressed: _extractFromVideo, child: const Text('重试')),
            TextButton(
                onPressed: () => setState(() => _extract = null),
                child: const Text('关闭')),
          ]),
        ]),
      );
    }
    return const SizedBox.shrink();
  }

  /// 空脚本的起步引导（见 start_guide.dart）
  Widget _startGuide() => StartGuide(
        canExtract: ref.watch(scriptTranscriberProvider) != null,
        onExtract: _extractFromVideo,
        onWrite: () => setState(() => _guideDismissed = true),
      );

  /// 预览舞台：竖屏幕布居中、限高——播放器窄而居中，不做顶天立地的黑洞。
  /// 幕布下挂一条禁用态的时间码，先把「这里将来是播放器」这件事说清楚
  Widget _previewStage() => Container(
        color: AppColors.background,
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xl, vertical: AppSpacing.xxl),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 560),
                child: AspectRatio(
                  aspectRatio: 9 / 16,
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.stageBackground,
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.play_circle_outline,
                              size: 28,
                              color: AppColors.textTertiary
                                  .withValues(alpha: 0.55)),
                          const SizedBox(height: AppSpacing.sm),
                          const Text('配音与镜头就绪后，在这里试片',
                              style: TextStyle(
                                  fontSize: AppFontSize.caption,
                                  color: AppColors.textTertiary)),
                        ]),
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            // 传输条骨架（禁用态）：预告播放器的形状，而不是又一句解释
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.play_arrow,
                  size: 18, color: AppColors.textTertiary.withValues(alpha: 0.4)),
              const SizedBox(width: AppSpacing.sm),
              Text('00:00 / 00:00',
                  style: TextStyle(
                      fontSize: AppFontSize.caption,
                      color: AppColors.textTertiary.withValues(alpha: 0.5),
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ]),
          ]),
        ),
      );

  Widget _blockedView() => Scaffold(
        backgroundColor: AppColors.background,
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('「$_blockedBy」正在处理这个任务',
                style: const TextStyle(
                    fontSize: AppFontSize.title,
                    color: AppColors.textPrimary)),
            const SizedBox(height: AppSpacing.sm),
            const Text('等它结束再进（谁先进谁处理）',
                style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: AppFontSize.caption)),
            const SizedBox(height: AppSpacing.lg),
            Row(mainAxisSize: MainAxisSize.min, children: [
              OutlinedButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('返回')),
              const SizedBox(width: AppSpacing.sm),
              FilledButton(
                  onPressed: _forceTakeover, child: const Text('强制接管')),
            ]),
          ]),
        ),
      );
}
