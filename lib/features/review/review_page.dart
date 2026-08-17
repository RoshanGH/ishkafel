import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/export/speed_fit.dart';
import '../../core/ffmpeg/process_runner.dart';
import '../../core/ffmpeg/thumbnail_service.dart';
import '../../core/models/renew_task.dart';
import '../../core/replacement/picked_material.dart';
import '../../core/review/review_receipt.dart';
import '../../core/storage/task_lock.dart';
import '../picking/picking_providers.dart';
import '../settings/settings_providers.dart';
import '../tasks/task_list_controller.dart';
import 'review_hover_player.dart';

/// 审核页：人过一遍 Agent 挑的候选，点掉不要的，一次确认。
///
/// 「Agent 干活 → 人把关 → 导出」闭环里人把关那一环。交互按「快速扫片」
/// 设计：**悬停即播**（有声、循环）、**点卡片即剔除/恢复**——审核是把
/// 不要的挑出来，不是重新挑一遍，所以不摆一排勾选框。
///
/// 版式：左侧位置栏（结构 + 进度，点击跳到对应段），右侧按位置分组的卡片
/// 网格。确认那一刻剔除落进任务、写回执（见 [ReviewReceipt]），Agent 用
/// `review-result` 取结果。
class ReviewPage extends ConsumerStatefulWidget {
  final RenewTask task;

  /// 测试注入：假播放器（真实现碰 libmpv）、假素材解析、假抽帧
  final ReviewHoverPlayer? hoverPlayer;
  final Future<String> Function(int materialId)? resolveMedia;
  final Future<String?> Function(int startMs, int endMs)? extractOriginalThumb;

  const ReviewPage({
    super.key,
    required this.task,
    this.hoverPlayer,
    this.resolveMedia,
    this.extractOriginalThumb,
  });

  @override
  ConsumerState<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends ConsumerState<ReviewPage> {
  late final List<ReviewItem> _items =
      collectReviewItems(widget.task.replacements ?? const []);

  /// 被剔除的候选。默认空 = 全保留：审核是把不要的挑出来
  final Set<String> _dropped = {};

  late final ReviewHoverPlayer _hover =
      widget.hoverPlayer ?? MediaKitHoverPlayer();

  /// 当前悬停在哪张卡上（null = 没有）。整页共用一个播放器，
  /// 只有这张卡把缩略图换成视频
  String? _hoveringKey;
  Timer? _hoverDebounce;

  final ScrollController _scroll = ScrollController();
  final Map<String, GlobalKey> _sectionKeys = {};

  bool _confirmed = false;
  String? _error;

  /// 原片段落的首帧图（分组 id → 本地 jpg）。抽出来一张补一张
  final Map<String, String> _originThumbs = {};

  static String keyOf(ReviewItem item) =>
      '${item.unit}/${item.shot}/${item.material}';

  @override
  void initState() {
    super.initState();
    _loadOriginThumbs();
  }

  /// 给每个位置组的原片段落抽一张首帧图（取中点：两端常踩在转场上，
  /// 抽出来是糊的）。按任务缓存，抽过的直接用
  Future<void> _loadOriginThumbs() async {
    if (widget.task.sourcePath == null) return;
    for (final section in _sections) {
      final start = section.originStartMs;
      final end = section.originEndMs;
      if (start == null || end == null) continue;
      try {
        final path = await (widget.extractOriginalThumb ?? _extractThumb)(
            start, end);
        if (!mounted) return;
        if (path != null && File(path).existsSync()) {
          setState(() => _originThumbs[section.id] = path);
        }
      } catch (_) {
        // 抽不出来就保持占位图，悬停仍能播真画面——不值得为一张缩略图报错
      }
    }
  }

  Future<String?> _extractThumb(int startMs, int endMs) async {
    final dataDir = ref.read(dataDirProvider);
    final source = widget.task.sourcePath;
    if (dataDir == null || source == null) return null;
    final dir = Directory(
        p.join(dataDir.path, 'review_thumbs', widget.task.id))
      ..createSync(recursive: true);
    final out = p.join(dir.path, 'orig_${startMs}_$endMs.jpg');
    if (File(out).existsSync()) return out;
    await ThumbnailService(run: const ResolvingProcessRunner().call)
        .extractCover(
      videoPath: source,
      outPath: out,
      atSeconds: ((startMs + endMs) / 2) / 1000.0,
      height: 480,
    );
    return out;
  }

  @override
  void dispose() {
    _hoverDebounce?.cancel();
    _hover.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ---- 数据视图 ----

  PickedMaterial? _materialOf(int id) {
    for (final m in widget.task.pickedMaterials) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// 标了 ★ 的那些（预览版）：审核的人该知道哪条是 Agent 的首选
  late final Set<String> _previewKeys = () {
    final keys = <String>{};
    final replacements = widget.task.replacements ?? const [];
    for (var u = 0; u < replacements.length; u++) {
      final r = replacements[u];
      if (r.wholeCandidateIds.isNotEmpty) {
        keys.add('$u/null/${r.wholePreviewId ?? r.wholeCandidateIds.first}');
      }
      for (final e in r.shotCandidateIds.entries) {
        if (e.value.isEmpty) continue;
        keys.add('$u/${e.key}/${r.shotPreviewIds[e.key] ?? e.value.first}');
      }
    }
    return keys;
  }();

  /// 位置分组（保持出现顺序）
  late final List<_Section> _sections = () {
    final map = <String, _Section>{};
    final units = widget.task.units ?? const [];
    for (final item in _items) {
      final id = '${item.unit}/${item.shot}';
      map.putIfAbsent(id, () {
        final unit = item.unit < units.length ? units[item.unit] : null;
        final shot = unit != null &&
                item.shot != null &&
                item.shot! < unit.shots.length
            ? unit.shots[item.shot!]
            : null;
        // 原片这一段的区间：整段替换是整个单元，镜头替换是那个镜头
        final originStart = item.shot == null ? unit?.startMs : shot?.startMs;
        final originEnd = item.shot == null ? unit?.endMs : shot?.endMs;
        return _Section(
          id: id,
          title: item.shot == null
              ? 'U${item.unit + 1} · 整段替换'
              : 'U${item.unit + 1} · S${item.shot! + 1}',
          transcript: unit?.transcript ?? '',
          slotMs: item.shot == null ? null : shot?.durationMs,
          originStartMs: originStart,
          originEndMs: originEnd,
          items: [],
        );
      });
      map[id]!.items.add(item);
    }
    return map.values.toList();
  }();

  int get _droppedCount => _dropped.length;

  // ---- 交互 ----

  void _toggle(ReviewItem item) {
    final key = keyOf(item);
    setState(() {
      _dropped.contains(key) ? _dropped.remove(key) : _dropped.add(key);
    });
  }

  void _onHover(
    String key,
    bool entered, {
    required Future<String> Function() resolve,
    int? startMs,
    int? endMs,
  }) {
    _hoverDebounce?.cancel();
    if (!entered) {
      if (_hoveringKey == key) {
        setState(() => _hoveringKey = null);
        _hover.stop();
      }
      return;
    }
    // 250ms 防抖：鼠标扫过一排卡时别把每张都拉起来播一下
    _hoverDebounce = Timer(const Duration(milliseconds: 250), () async {
      if (!mounted) return;
      setState(() => _hoveringKey = key);
      try {
        final path = await resolve();
        if (!mounted || _hoveringKey != key) return;
        await _hover.play(path, startMs: startMs, endMs: endMs);
      } catch (_) {
        if (mounted && _hoveringKey == key) {
          setState(() => _hoveringKey = null);
        }
      }
    });
  }

  Future<String> _resolveMaterial(int id) {
    final resolve = widget.resolveMedia ??
        (int id) async {
          final fetch = ref.read(materialFetcherProvider);
          if (fetch == null) throw StateError('素材下载器未就绪');
          return fetch(id);
        };
    return resolve(id);
  }

  void _jumpTo(String sectionId) {
    final key = _sectionKeys[sectionId];
    final ctx = key?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 250),
          alignment: 0,
          curve: Curves.easeOut);
    }
  }

  Future<void> _confirm() async {
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) {
      setState(() => _error = '数据目录未就绪，确认不了');
      return;
    }
    // 写任务前要拿锁：Agent 可能还在操作这条任务
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
            keep: !_dropped.contains(keyOf(item)),
          ),
      ];
      final repo = ref.read(taskRepositoryProvider);
      // 以盘上最新的为准：审核期间 Agent 可能改过任务
      final current = await repo.findById(widget.task.id) ?? widget.task;
      final pruned =
          applyReviewDecisions(current.replacements ?? const [], decisions);
      await repo.save(
          current.copyWith(replacements: pruned, updatedAt: DateTime.now()));
      saveReviewReceipt(dataDir, widget.task.id,
          ReviewReceipt(reviewedAt: DateTime.now(), decisions: decisions));
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

  // ---- 视图 ----

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.surface,
          titleSpacing: 0,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('审核候选',
                  style: TextStyle(
                      fontSize: AppFontSize.emphasis,
                      fontWeight: FontWeight.w600)),
              Text(widget.task.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: AppFontSize.micro,
                      color: AppColors.textTertiary)),
            ],
          ),
        ),
        body: _items.isEmpty
            ? const _EmptyState()
            : (_confirmed ? _doneState() : _reviewBody()),
        bottomNavigationBar:
            _items.isEmpty || _confirmed ? null : _confirmBar(),
      );

  Widget _reviewBody() => Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _railView(),
          const VerticalDivider(width: 1, color: AppColors.border),
          Expanded(child: _sectionsView()),
        ],
      );

  /// 左栏：位置导航 + 进度。审核是逐位置过一遍的活，要能看到全貌
  Widget _railView() => SizedBox(
        width: 220,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(
                  AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.xs),
              child: Text('位置',
                  style: TextStyle(
                      fontSize: AppFontSize.caption,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondary)),
            ),
            for (final section in _sections)
              _RailRow(
                title: section.title,
                kept: section.items
                    .where((i) => !_dropped.contains(keyOf(i)))
                    .length,
                total: section.items.length,
                onTap: () => _jumpTo(section.id),
              ),
          ],
        ),
      );

  Widget _sectionsView() => ListView(
        controller: _scroll,
        padding: const EdgeInsets.all(AppSpacing.xl),
        children: [
          const Text('悬停播放，点击剔除/恢复。确认后被剔除的从方案里拿掉，其余照旧。',
              style: TextStyle(
                  fontSize: AppFontSize.caption,
                  color: AppColors.textTertiary)),
          const SizedBox(height: AppSpacing.lg),
          for (final section in _sections) ...[
            KeyedSubtree(
              key: _sectionKeys.putIfAbsent(section.id, GlobalKey.new),
              child: _sectionHeader(section),
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.md,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // 原片这一段打头：审核就是「原来是什么 → 换成什么」的对比
                if (widget.task.sourcePath != null &&
                    section.originStartMs != null &&
                    section.originEndMs != null) ...[
                  _originalCard(section),
                  const Icon(Icons.arrow_forward,
                      size: 18, color: AppColors.textTertiary),
                ],
                for (final item in section.items)
                  _card(item, slotMs: section.slotMs),
              ],
            ),
            const SizedBox(height: AppSpacing.xl),
          ],
        ],
      );

  Widget _sectionHeader(_Section section) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text(section.title,
                style: const TextStyle(
                    fontSize: AppFontSize.emphasis,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary)),
            if (section.slotMs case final ms?) ...[
              const SizedBox(width: AppSpacing.sm),
              Text('坑位 ${(ms / 1000).toStringAsFixed(1)}s',
                  style: const TextStyle(
                      fontSize: AppFontSize.caption,
                      color: AppColors.textTertiary)),
            ],
          ]),
          if (section.transcript.isNotEmpty)
            Container(
              constraints: const BoxConstraints(maxWidth: 720),
              padding: const EdgeInsets.only(top: 2),
              child: Text(section.transcript,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: AppFontSize.caption,
                      height: 1.5,
                      color: AppColors.textSecondary)),
            ),
        ],
      );

  /// 原片卡：这一段本来的样子。不可剔除（它不是候选，是参照物），
  /// 悬停播的是原片的这个区间
  Widget _originalCard(_Section section) {
    final key = 'orig/${section.id}';
    final hovering = _hoveringKey == key;
    final source = widget.task.sourcePath!;
    final start = section.originStartMs!;
    final end = section.originEndMs!;
    return MouseRegion(
      onEnter: (_) => _onHover(key, true,
          resolve: () async => source, startMs: start, endMs: end),
      onExit: (_) => _onHover(key, false,
          resolve: () async => source, startMs: start, endMs: end),
      child: Container(
        key: Key('review-original-${section.id}'),
        width: 150,
        decoration: BoxDecoration(
          color: AppColors.surfaceCard,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: hovering ? AppColors.accentBlue : AppColors.accentBlueLight,
            width: hovering ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 9 / 16,
              child: ClipRRect(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(8)),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_originThumbs[section.id] case final thumb?)
                      Image.file(File(thumb),
                          key: Key('review-original-thumb-${section.id}'),
                          fit: BoxFit.cover)
                    else
                      Container(
                          color: AppColors.surfaceCard,
                          child: const Icon(Icons.theaters_outlined,
                              size: 32, color: AppColors.textTertiary)),
                    if (hovering) _hover.buildVideo(),
                    Positioned(
                      left: 6,
                      top: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.accentBlue,
                          borderRadius: BorderRadius.circular(AppRadius.xs),
                        ),
                        child: const Text('原片',
                            style: TextStyle(
                                fontSize: AppFontSize.micro,
                                color: Colors.white)),
                      ),
                    ),
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child:
                          _chip('${((end - start) / 1000).toStringAsFixed(1)}s'),
                    ),
                  ],
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.all(AppSpacing.xs),
              child: Text('这一段本来的样子',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: AppFontSize.micro,
                      color: AppColors.textTertiary)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card(ReviewItem item, {int? slotMs}) {
    final key = keyOf(item);
    final material = _materialOf(item.material);
    final dropped = _dropped.contains(key);
    final hovering = _hoveringKey == key;
    final thumb = material?.thumbPath;

    // 镜头替换要变速对齐坑位：倍率如实标出来，人看一眼就知道会不会像快进
    String? rate;
    if (slotMs != null && slotMs > 0 && material?.durationMs != null) {
      rate = SpeedFit.describe(
          SpeedFit.factorFor(candidateMs: material!.durationMs!, slotMs: slotMs));
    }

    return MouseRegion(
      onEnter: (_) => _onHover(key, true,
          resolve: () => _resolveMaterial(item.material)),
      onExit: (_) => _onHover(key, false,
          resolve: () => _resolveMaterial(item.material)),
      child: GestureDetector(
        key: Key('review-card-$key'),
        onTap: () => _toggle(item),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 120),
          opacity: dropped ? 0.38 : 1,
          child: Container(
            width: 150,
            decoration: BoxDecoration(
              color: AppColors.surfaceRaised,
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(
                color: dropped
                    ? AppColors.red
                    : (hovering ? AppColors.accentBlue : AppColors.border),
                width: dropped || hovering ? 1.5 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AspectRatio(
                  aspectRatio: 9 / 16,
                  child: ClipRRect(
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(8)),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (thumb != null && File(thumb).existsSync())
                          Image.file(File(thumb), fit: BoxFit.cover)
                        else
                          Container(
                              color: AppColors.surfaceCard,
                              child: const Icon(Icons.movie_outlined,
                                  color: AppColors.textTertiary)),
                        // 悬停时缩略图上盖真视频（有声、循环）
                        if (hovering && !dropped) _hover.buildVideo(),
                        // 角标们
                        Positioned(
                          left: 6,
                          bottom: 6,
                          child: Row(children: [
                            if (material?.durationMs case final ms?)
                              _chip('${(ms / 1000).toStringAsFixed(1)}s'),
                            if (rate != null) ...[
                              const SizedBox(width: 4),
                              _chip(rate, color: AppColors.orange),
                            ],
                          ]),
                        ),
                        if (_previewKeys.contains(key))
                          Positioned(
                              right: 6, top: 6, child: _chip('★ 预览版')),
                        if (dropped)
                          Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: AppSpacing.sm,
                                  vertical: AppSpacing.xs),
                              decoration: BoxDecoration(
                                color: AppColors.red.withValues(alpha: 0.85),
                                borderRadius:
                                    BorderRadius.circular(AppRadius.sm),
                              ),
                              child: const Text('已剔除',
                                  style: TextStyle(
                                      fontSize: AppFontSize.caption,
                                      color: Colors.white)),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.xs),
                  child: Text(
                    material == null
                        ? '素材 ${item.material}'
                        : _tail(material.name),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: AppFontSize.micro,
                        color: AppColors.textTertiary),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _chip(String text, {Color? color}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(AppRadius.xs),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: AppFontSize.micro, color: color ?? Colors.white)),
      );

  static String _tail(String name) =>
      name.length <= 18 ? name : '…${name.substring(name.length - 17)}';

  Widget _confirmBar() => Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.md),
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
                      '共 ${_items.length} 条 · 保留 '
                          '${_items.length - _droppedCount} · '
                          '剔除 $_droppedCount',
                  style: TextStyle(
                      fontSize: AppFontSize.body,
                      color: _error == null
                          ? AppColors.textSecondary
                          : AppColors.orange),
                ),
              ),
              FilledButton(
                key: const Key('review-confirm'),
                onPressed: _confirm,
                child: Text(_droppedCount == 0
                    ? '确认 · 全部保留'
                    : '确认 · 剔除 $_droppedCount 条'),
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

class _Section {
  final String id;
  final String title;
  final String transcript;

  /// 镜头替换的固定坑位时长；整段替换为 null（时长跟素材走）
  final int? slotMs;

  /// 原片这一段的区间（悬停原片卡播的就是它）。空白任务没有原片时为 null
  final int? originStartMs;
  final int? originEndMs;
  final List<ReviewItem> items;

  _Section({
    required this.id,
    required this.title,
    required this.transcript,
    required this.slotMs,
    this.originStartMs,
    this.originEndMs,
    required this.items,
  });
}

class _RailRow extends StatelessWidget {
  final String title;
  final int kept;
  final int total;
  final VoidCallback onTap;

  const _RailRow(
      {required this.title,
      required this.kept,
      required this.total,
      required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: AppSpacing.sm),
          child: Row(
            children: [
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontSize: AppFontSize.caption,
                        color: AppColors.textPrimary)),
              ),
              Text(
                kept == total ? '$total 条' : '$kept/$total',
                style: TextStyle(
                    fontSize: AppFontSize.micro,
                    // 有剔除的位置标橙——一眼看出哪儿动过刀
                    color: kept == total
                        ? AppColors.textTertiary
                        : AppColors.orange),
              ),
            ],
          ),
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
