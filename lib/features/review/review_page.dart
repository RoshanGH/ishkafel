import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/models/renew_task.dart';
import '../../core/replacement/picked_material.dart';
import '../../core/review/review_receipt.dart';
import '../../core/storage/task_lock.dart';
import '../settings/settings_providers.dart';
import '../tasks/task_list_controller.dart';
import 'review_preview.dart';

/// 审核页：人过一遍 Agent 挑的候选，勾选去留，一次确认。
///
/// 「Agent 干活 → 人把关 → 导出」闭环里人把关那一环。为什么由软件提供而
/// 不是让 Agent 现造页面：回执格式与剔除逻辑必须是固定契约（见
/// [ReviewReceipt]）；播放的必须是本地落好的素材，Agent 手里的签名地址
/// 隔天就 403——**看到的就是要交付的**，这只有软件自己能保证。
///
/// 确认那一刻做三件事：剔除落进任务（[applyReviewDecisions]）、写回执、
/// 通知列表刷新。Agent 之后用 `ishkafel review-result` 取回执，不需要
/// 也不应该再改一遍方案。
class ReviewPage extends ConsumerStatefulWidget {
  final RenewTask task;

  /// 播放一条素材。测试注入假实现，免得碰 libmpv
  final ReviewPreviewOpener? onPlay;

  const ReviewPage({super.key, required this.task, this.onPlay});

  @override
  ConsumerState<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends ConsumerState<ReviewPage> {
  late final List<ReviewItem> _items =
      collectReviewItems(widget.task.replacements ?? const []);

  /// 每条候选的去留，默认保留——审核是「把不要的挑出来」，不是重挑一遍
  late final Map<String, bool> _keep = {
    for (final item in _items) _keyOf(item): true,
  };

  bool _confirmed = false;
  String? _error;

  static String _keyOf(ReviewItem item) =>
      '${item.unit}/${item.shot}/${item.material}';

  PickedMaterial? _materialOf(int id) {
    for (final m in widget.task.pickedMaterials) {
      if (m.id == id) return m;
    }
    return null;
  }

  int get _droppedCount => _keep.values.where((keep) => !keep).length;

  Future<void> _confirm() async {
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) {
      setState(() => _error = '数据目录未就绪，确认不了');
      return;
    }
    // 写任务前要拿锁：Agent 可能还在操作这条任务，两边同时写会互相覆盖
    final lock = TaskLockFile(dataDir: dataDir, taskId: widget.task.id);
    if (!lock.acquire('review')) {
      setState(() => _error =
          '${lock.read()?.holder ?? '别人'} 正在操作这个任务，等它结束再确认');
      return;
    }
    try {
      final decisions = [
        for (final item in _items)
          ReviewDecision(
            unit: item.unit,
            shot: item.shot,
            material: item.material,
            keep: _keep[_keyOf(item)] ?? true,
          ),
      ];
      final repo = ref.read(taskRepositoryProvider);
      // 以盘上最新的为准：审核期间 Agent 可能改过任务
      final current = await repo.findById(widget.task.id) ?? widget.task;
      final pruned =
          applyReviewDecisions(current.replacements ?? const [], decisions);
      await repo.save(
          current.copyWith(replacements: pruned, updatedAt: DateTime.now()));
      saveReviewReceipt(
        dataDir,
        widget.task.id,
        ReviewReceipt(reviewedAt: DateTime.now(), decisions: decisions),
      );
      await ref.read(taskListProvider.notifier).reload();
      if (!mounted) return;
      setState(() {
        _confirmed = true;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '确认失败：$e');
    } finally {
      lock.release('review');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.surface,
          title: Text('审核候选 · ${widget.task.name}',
              style: const TextStyle(fontSize: AppFontSize.emphasis)),
        ),
        body: _items.isEmpty
            ? const _EmptyState()
            : (_confirmed ? _doneState() : _reviewBody()),
        bottomNavigationBar:
            _items.isEmpty || _confirmed ? null : _confirmBar(),
      );

  Widget _reviewBody() {
    // 按位置分组展示：一个坑位的几条候选摆在一起才好比
    final groups = <String, List<ReviewItem>>{};
    for (final item in _items) {
      final key = item.shot == null
          ? 'U${item.unit + 1} · 整段替换'
          : 'U${item.unit + 1} 的 S${item.shot! + 1}';
      (groups[key] ??= []).add(item);
    }
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        const Text(
          '这些是 Agent 挑的候选。不要的取消勾选，然后点底下的「确认」——'
          '被剔除的会从方案里拿掉，其余照旧。',
          style: TextStyle(
              fontSize: AppFontSize.caption,
              height: 1.6,
              color: AppColors.textSecondary),
        ),
        const SizedBox(height: AppSpacing.md),
        for (final entry in groups.entries) ...[
          _groupHeader(entry.key, entry.value.first),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [for (final item in entry.value) _card(item)],
          ),
          const SizedBox(height: AppSpacing.lg),
        ],
      ],
    );
  }

  Widget _groupHeader(String title, ReviewItem first) {
    final units = widget.task.units ?? const [];
    final transcript = first.unit < units.length
        ? units[first.unit].transcript
        : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: const TextStyle(
                fontSize: AppFontSize.body,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary)),
        if (transcript.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(transcript,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: AppFontSize.caption,
                    color: AppColors.textTertiary)),
          ),
      ],
    );
  }

  Widget _card(ReviewItem item) {
    final material = _materialOf(item.material);
    final key = _keyOf(item);
    final keep = _keep[key] ?? true;
    final thumb = material?.thumbPath;
    return Container(
      width: 148,
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
          // 被剔除的一眼能认出来：红边 + 半透明
          color: keep ? AppColors.border : AppColors.red,
        ),
      ),
      child: Opacity(
        opacity: keep ? 1 : 0.45,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 首帧图：本地文件，不依赖会过期的签名地址
            AspectRatio(
              aspectRatio: 9 / 16,
              child: ClipRRect(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(8)),
                child: thumb != null && File(thumb).existsSync()
                    ? Image.file(File(thumb), fit: BoxFit.cover)
                    : Container(
                        color: AppColors.surfaceCard,
                        child: const Icon(Icons.movie_outlined,
                            color: AppColors.textTertiary)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.xs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    material == null
                        ? '素材 ${item.material}'
                        : _tail(material.name),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: AppFontSize.micro,
                        color: AppColors.textSecondary),
                  ),
                  Row(
                    children: [
                      if (material?.durationMs case final ms?)
                        Text('${(ms / 1000).toStringAsFixed(1)}s',
                            style: const TextStyle(
                                fontSize: AppFontSize.micro,
                                color: AppColors.textTertiary)),
                      const Spacer(),
                      IconButton(
                        key: Key('review-play-$key'),
                        visualDensity: VisualDensity.compact,
                        tooltip: '播放',
                        icon: const Icon(Icons.play_circle_outline, size: 18),
                        color: AppColors.accentBlue,
                        onPressed: () => (widget.onPlay ?? showReviewPreview)(
                            context, ref, item.material,
                            name: material?.name ?? '素材 ${item.material}'),
                      ),
                      Checkbox(
                        key: Key('review-keep-$key'),
                        value: keep,
                        onChanged: (v) =>
                            setState(() => _keep[key] = v ?? true),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _tail(String name) =>
      name.length <= 16 ? name : '…${name.substring(name.length - 15)}';

  Widget _confirmBar() => Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: const BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: SafeArea(
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _error ??
                      '保留 ${_items.length - _droppedCount} 条 · '
                          '剔除 $_droppedCount 条',
                  style: TextStyle(
                      fontSize: AppFontSize.caption,
                      color: _error == null
                          ? AppColors.textSecondary
                          : AppColors.orange),
                ),
              ),
              FilledButton(
                key: const Key('review-confirm'),
                onPressed: _confirm,
                child: const Text('确认'),
              ),
            ],
          ),
        ),
      );

  Widget _doneState() => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.check_circle_outline,
                size: 48, color: AppColors.green),
            const SizedBox(height: AppSpacing.md),
            Text(
              '审核完成：保留 ${_items.length - _droppedCount} 条，'
              '剔除 $_droppedCount 条。\n'
              '剔除已落进任务，Agent 用 review-result 就能取到结果。',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: AppFontSize.body,
                  height: 1.8,
                  color: AppColors.textPrimary),
            ),
          ],
        ),
      );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => const Center(
        child: Text('这条任务还没有挑过任何候选，没有可审核的。',
            style: TextStyle(color: AppColors.textTertiary)),
      );
}

/// 首帧图找不到时兜底用（保留引用，避免误删 path 依赖）
String reviewThumbFallback(Directory dataDir) =>
    p.join(dataDir.path, 'picked_thumbs');
