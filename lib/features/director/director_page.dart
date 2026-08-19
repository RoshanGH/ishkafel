import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/log/app_log.dart';
import '../../core/models/renew_task.dart';
import '../../core/script/script_doc.dart';
import '../../core/storage/task_lock.dart';
import '../../core/storage/task_repository.dart';
import '../settings/settings_providers.dart';
import '../tasks/task_list_controller.dart';
import 'script_panel.dart';

/// 编导台——「脚本成片」的工作页（对仗审片台）。
///
/// 三栏：左 = 脚本（唯一的真相 + 总览导航）；中 = 预览（成片的影子）；
/// 右 = 当前行的工作台（聚焦深工）。见 docs/2026-08-19 设计稿。
///
/// M1 骨架：脚本编辑 + 落盘 + 锁；预览与行工作台后续里程碑点亮
/// （占位必须说明自己是什么，不摆死界面）。
class DirectorPage extends ConsumerStatefulWidget {
  final RenewTask task;

  const DirectorPage({super.key, required this.task});

  @override
  ConsumerState<DirectorPage> createState() => _DirectorPageState();
}

class _DirectorPageState extends ConsumerState<DirectorPage> {
  late RenewTask _task = widget.task;
  late ScriptDoc _doc = widget.task.script ?? ScriptDoc.empty();
  int _selected = 0;

  Timer? _autosave;
  TaskLockFile? _lock;
  Timer? _lockHeartbeat;
  String? _blockedBy;

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

  /// 改动随手落库（800ms 防抖），与审片台同一习惯——没有「保存」这回事
  void _mutate(ScriptDoc Function(ScriptDoc) f) {
    setState(() => _doc = f(_doc));
    _autosave?.cancel();
    _autosave = Timer(const Duration(milliseconds: 800), _flushNow);
  }

  void _flushNow() {
    _autosave?.cancel();
    _task = _task.copyWith(script: _doc);
    unawaited(_repo.save(_task).catchError((Object e) {
      AppLog.warn('脚本落库失败（taskId=${_task.id}）：$e');
    }));
  }

  @override
  Widget build(BuildContext context) {
    if (_blockedBy != null) return _blockedView();
    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        leading: BackButton(onPressed: () => Navigator.of(context).maybePop()),
        title: Text('${_task.name} · 编导台',
            style: const TextStyle(
                fontSize: AppFontSize.emphasis, fontWeight: FontWeight.w600)),
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 左：脚本——唯一的真相
          SizedBox(
            width: 380,
            child: ScriptPanel(
              doc: _doc,
              selected: _selected,
              onSelect: (i) => setState(() => _selected = i),
              onInsertAfter: (i) {
                _mutate((d) => d.insertAfter(i));
                setState(() => _selected = i + 1);
              },
              onRemove: (i) {
                _mutate((d) => d.removeAt(i));
                if (_selected >= _doc.lines.length) {
                  setState(() => _selected = _doc.lines.length - 1);
                }
              },
              onMove: (from, to) {
                _mutate((d) => d.move(from, to));
                setState(() => _selected = to);
              },
              onTextChanged: (i, text) => _mutate((d) => d.updateText(i, text)),
            ),
          ),
          const VerticalDivider(width: 1, color: AppColors.border),
          // 中：预览（M4 点亮）
          Expanded(child: _previewPlaceholder()),
          const VerticalDivider(width: 1, color: AppColors.border),
          // 右：当前行工作台（M2 配音 / M3 镜头逐步点亮）
          SizedBox(width: 360, child: _lineWorkbench()),
        ],
      ),
    );
  }

  Widget _previewPlaceholder() => Container(
        color: AppColors.surfaceCard,
        alignment: Alignment.center,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          AspectRatio(
            aspectRatio: 9 / 16,
            child: Container(
              margin: const EdgeInsets.all(AppSpacing.xl),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              alignment: Alignment.center,
              child: const Text('预览\n配音与镜头就绪后在这里试片',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: AppFontSize.caption,
                      height: 1.6)),
            ),
          ),
        ]),
      );

  Widget _lineWorkbench() {
    if (_selected < 0 || _selected >= _doc.lines.length) {
      return const SizedBox.shrink();
    }
    final line = _doc.lines[_selected];
    final voiced = line.type == ScriptLineType.voiced;
    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('第 ${_selected + 1} 行 · ${voiced ? '配音行' : '画面行'}',
              style: const TextStyle(
                  fontSize: AppFontSize.body, fontWeight: FontWeight.w600)),
          const SizedBox(height: AppSpacing.xs),
          Text(
              voiced
                  ? '配音时长将是这一行时间轴的根'
                  : '没有台词——有画面、可铺配乐；时长手填或跟随所选素材',
              style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: AppFontSize.caption,
                  height: 1.5)),
          const SizedBox(height: AppSpacing.lg),
          if (!voiced) _manualMsField(line),
          const Spacer(),
          const Text('配音与镜头工作台在后续版本点亮',
              style: TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: AppFontSize.caption)),
        ],
      ),
    );
  }

  /// 画面行的手填时长：设计稿——手填即根，不填随所选素材
  Widget _manualMsField(ScriptLine line) {
    final seconds = line.manualMs == null
        ? ''
        : (line.manualMs! / 1000).toStringAsFixed(1);
    return Row(children: [
      const Text('时长',
          style: TextStyle(
              color: AppColors.textSecondary, fontSize: AppFontSize.body)),
      const SizedBox(width: AppSpacing.sm),
      SizedBox(
        width: 90,
        child: TextFormField(
          key: ValueKey('manual-ms-${line.id}'),
          initialValue: seconds,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
              isDense: true, suffixText: '秒', hintText: '随素材'),
          onChanged: (v) {
            final parsed = double.tryParse(v.trim());
            _mutate((d) => d.setManualMs(_selected,
                parsed == null || parsed <= 0 ? null : (parsed * 1000).round()));
          },
        ),
      ),
      const SizedBox(width: AppSpacing.sm),
      const Expanded(
        child: Text('不填则跟随所选素材的时长',
            style: TextStyle(
                color: AppColors.textTertiary, fontSize: AppFontSize.caption)),
      ),
    ]);
  }

  Widget _blockedView() => Scaffold(
        backgroundColor: AppColors.surface,
        appBar: AppBar(backgroundColor: AppColors.surface),
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('「$_blockedBy」正在处理这个任务',
                style: const TextStyle(fontSize: AppFontSize.emphasis)),
            const SizedBox(height: AppSpacing.sm),
            const Text('等它结束再进（谁先进谁处理）',
                style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: AppFontSize.caption)),
            const SizedBox(height: AppSpacing.md),
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
