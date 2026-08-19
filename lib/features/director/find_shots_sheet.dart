import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/log/app_log.dart';
import '../../core/models/renew_task.dart';
import '../../core/script/line_tagger.dart';
import '../../core/script/script_doc.dart';
import '../picking/candidate_search_controller.dart';
import 'director_providers.dart';

/// 给一行找镜头（M3）。
///
/// 标签是所有检索的**公共筛选层**（设计稿）：行标签自动预填成 chips、
/// 可勾选可增删；按标签搜或按画面描述搜。挑中的镜头按顺序落到行上。
/// 防撞车：同任务其他行已用的素材打上「第 N 行在用」角标——能选，但看得见。
/// 面板的产出：镜头序列 + （可能在面板里增删过的）行标签
class FindShotsResult {
  final List<LineShot> shots;
  final List<String> tags;
  const FindShotsResult({required this.shots, required this.tags});
}

Future<FindShotsResult?> showFindShotsSheet(
  BuildContext context, {
  required ShotSearchServices services,
  required LineTagger? tagger,
  required RenewTask task,
  required int lineIndex,
  required ScriptLine line,

  /// materialId → 用在第几行（0 起，含本行；本行的用于回显已选）
  required Map<int, int> usedBy,
}) =>
    showDialog<FindShotsResult>(
      context: context,
      builder: (_) => _FindShotsSheet(
        services: services,
        tagger: tagger,
        task: task,
        lineIndex: lineIndex,
        line: line,
        usedBy: usedBy,
      ),
    );

class _FindShotsSheet extends StatefulWidget {
  final ShotSearchServices services;
  final LineTagger? tagger;
  final RenewTask task;
  final int lineIndex;
  final ScriptLine line;
  final Map<int, int> usedBy;

  const _FindShotsSheet({
    required this.services,
    required this.tagger,
    required this.task,
    required this.lineIndex,
    required this.line,
    required this.usedBy,
  });

  @override
  State<_FindShotsSheet> createState() => _FindShotsSheetState();
}

class _FindShotsSheetState extends State<_FindShotsSheet> {
  late final CandidateSearchController _search = CandidateSearchController(
    service: widget.services.content,
    probe: widget.services.probe,
    projectIds: [if (widget.task.project != null) widget.task.project!.id],
  );

  late final TextEditingController _keyword =
      TextEditingController(text: widget.line.text.trim());

  /// 检索用的标签（预填行标签；勾选状态就在这里维护）
  late final List<String> _tags = [...widget.line.tags];
  late final Set<String> _enabledTags = {...widget.line.tags};

  /// 标签名 → miaoa 标签 id。打开面板时按任务的分子标签组拉一次
  Map<String, int>? _tagIds;
  String? _tagIdsError;

  bool _byTags = true;
  bool _tagging = false;

  /// 正在按哪条素材找相似（以图搜图）；null = 不在相似模式
  String? _similarToName;

  /// 已选镜头（保持加入顺序；预填本行已有的）
  late final List<LineShot> _picked = [...widget.line.shots];

  @override
  void initState() {
    super.initState();
    _search.addListener(_onSearch);
    _bootstrap();
  }

  void _onSearch() => setState(() {});

  Future<void> _bootstrap() async {
    await _loadTagIds();
    if (!mounted) return;
    // 自动预搜（设计稿：默认全自动预填，人只做否决）：
    // 有能映射的标签就按标签搜，否则退回按台词的画面描述搜
    if (_byTags && _enabledTagIds.isNotEmpty) {
      await _search.searchByTags(tagIds: _enabledTagIds);
    } else if (_keyword.text.trim().isNotEmpty) {
      setState(() => _byTags = false);
      await _search.searchByDescription(_keyword.text);
    }
  }

  Future<void> _loadTagIds() async {
    try {
      final groups = await widget.services.tags.listGroups();
      final wanted = {for (final g in widget.task.unitTagGroups) g.id};
      final ids = <String, int>{};
      for (final g in groups) {
        if (!wanted.contains(g.id)) continue;
        final infos = await widget.services.tags.listTags(g.id);
        for (final t in infos) {
          ids.putIfAbsent(t.name, () => t.id);
        }
      }
      if (mounted) setState(() => _tagIds = ids);
    } catch (e) {
      AppLog.warn('找镜头面板拉标签词表失败：$e');
      if (mounted) {
        setState(() => _tagIdsError = '标签词表拉取失败，按标签搜不可用（可用画面描述搜）');
      }
    }
  }

  List<int> get _enabledTagIds => [
        for (final name in _tags)
          if (_enabledTags.contains(name)) ?_tagIds?[name],
      ];

  Future<void> _runSearch() async {
    if (_byTags) {
      final ids = _enabledTagIds;
      if (ids.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('没有可用的标签（未勾选或词表里对不上），试试画面描述搜。')));
        return;
      }
      await _search.searchByTags(tagIds: ids);
    } else {
      if (_keyword.text.trim().isEmpty) return;
      await _search.searchByDescription(_keyword.text);
    }
  }

  /// 以图搜图：拿一条候选的首帧找同款（设计稿的第三种检索）
  Future<void> _searchSimilar(CandidateEntry entry) async {
    final fileKey = entry.material.fileKey;
    if (fileKey == null || fileKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('这条素材没有可用的查询帧，搜不了相似。')));
      return;
    }
    final m = entry.material;
    setState(() => _similarToName =
        m.voiceover.isNotEmpty ? m.voiceover : m.name);
    await _search.searchByImage(fileKey);
  }

  /// 自动打标：AI 从任务标签组的词表里给这行台词挑标签
  Future<void> _autoTag() async {
    final tagger = widget.tagger;
    if (tagger == null) return;
    setState(() => _tagging = true);
    try {
      final tags = await tagger.tag(
        text: widget.line.text,
        groups: widget.task.unitTagGroups,
        constraint: widget.task.unitTagPrompt,
      );
      if (!mounted) return;
      setState(() {
        for (final t in tags) {
          if (!_tags.contains(t)) _tags.add(t);
          _enabledTags.add(t);
        }
      });
      if (tags.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('这行台词没有匹配到词表里的标签。')));
      } else {
        await _runSearch();
      }
    } catch (e) {
      AppLog.warn('行自动打标失败：$e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('自动打标失败，请稍后重试。')));
      }
    } finally {
      if (mounted) setState(() => _tagging = false);
    }
  }

  @override
  void dispose() {
    _search.removeListener(_onSearch);
    _search.dispose();
    _keyword.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg)),
      child: SizedBox(
        width: 920,
        height: 660,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.xl, AppSpacing.lg, AppSpacing.xl, 0),
            child: Row(children: [
              Text('给第 ${widget.lineIndex + 1} 行找镜头',
                  style: const TextStyle(
                      fontSize: AppFontSize.title,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary)),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(widget.line.text.trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: AppFontSize.caption,
                        color: AppColors.textTertiary)),
              ),
            ]),
          ),
          const SizedBox(height: AppSpacing.md),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
            child: _searchBar(),
          ),
          const SizedBox(height: AppSpacing.sm),
          const Divider(height: 1, color: AppColors.border),
          Expanded(child: _results()),
          const Divider(height: 1, color: AppColors.border),
          _footer(),
        ]),
      ),
    );
  }

  Widget _searchBar() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        _modePill('按标签', _byTags, () {
          setState(() => _byTags = true);
          if (_enabledTagIds.isNotEmpty) _runSearch();
        }),
        const SizedBox(width: AppSpacing.xs),
        _modePill('按画面描述', !_byTags, () => setState(() => _byTags = false)),
        if (_similarToName != null) ...[
          const SizedBox(width: AppSpacing.sm),
          Flexible(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.accentBlue.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Flexible(
                  child: Text('相似于：$_similarToName',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: AppFontSize.micro,
                          color: AppColors.accentBlueLight)),
                ),
                const SizedBox(width: 4),
                InkWell(
                  onTap: () {
                    setState(() => _similarToName = null);
                    _runSearch();
                  },
                  child: const Icon(Icons.close,
                      size: 11, color: AppColors.accentBlueLight),
                ),
              ]),
            ),
          ),
        ],
        const Spacer(),
        if (_byTags && widget.tagger != null)
          TextButton.icon(
            key: const ValueKey('shots-auto-tag'),
            onPressed: _tagging ? null : _autoTag,
            icon: _tagging
                ? const SizedBox(
                    width: 11,
                    height: 11,
                    child: CircularProgressIndicator(strokeWidth: 1.5))
                : const Icon(Icons.auto_awesome, size: 13),
            label: Text(_tagging ? '打标中…' : '自动打标',
                style: const TextStyle(fontSize: AppFontSize.caption)),
          ),
      ]),
      const SizedBox(height: AppSpacing.sm),
      if (_byTags) _tagChips() else _keywordField(),
    ]);
  }

  Widget _tagChips() {
    if (_tagIdsError != null) {
      return Text(_tagIdsError!,
          style:
              const TextStyle(fontSize: AppFontSize.caption, color: AppColors.orange));
    }
    if (_tags.isEmpty) {
      return Text(
          widget.tagger == null
              ? '这一行还没有标签。可以切到「按画面描述」直接搜'
              : '这一行还没有标签——点右上「自动打标」让 AI 从词表里挑，或切到「按画面描述」直接搜',
          style: const TextStyle(
              fontSize: AppFontSize.caption, color: AppColors.textTertiary));
    }
    return Wrap(spacing: AppSpacing.xs, runSpacing: AppSpacing.xs, children: [
      for (final tag in _tags)
        FilterChip(
          key: ValueKey('shot-tag-$tag'),
          label: Text(tag, style: const TextStyle(fontSize: AppFontSize.caption)),
          selected: _enabledTags.contains(tag),
          visualDensity: VisualDensity.compact,
          onSelected: (on) {
            setState(() => on ? _enabledTags.add(tag) : _enabledTags.remove(tag));
            _runSearch();
          },
        ),
    ]);
  }

  Widget _keywordField() => Row(children: [
        Expanded(
          child: TextField(
            key: const ValueKey('shots-keyword'),
            controller: _keyword,
            style: const TextStyle(fontSize: AppFontSize.body),
            decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 15),
                hintText: '描述想要的画面，例如「厨房喷洒清洁剂」'),
            onSubmitted: (_) => _runSearch(),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        FilledButton(
            key: const ValueKey('shots-search'),
            onPressed: _runSearch,
            child: const Text('搜索')),
      ]);

  Widget _modePill(String label, bool selected, VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.accentBlue.withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
                color: selected ? AppColors.accentBlue : AppColors.border),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: AppFontSize.caption,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected
                      ? AppColors.accentBlueLight
                      : AppColors.textSecondary)),
        ),
      );

  Widget _results() {
    switch (_search.status) {
      case CandidateSearchStatus.idle:
        return const Center(
            child: Text('选好标签或写好描述，候选会出现在这里',
                style: TextStyle(
                    fontSize: AppFontSize.body,
                    color: AppColors.textTertiary)));
      case CandidateSearchStatus.loading:
        return const Center(
            child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2)));
      case CandidateSearchStatus.failed:
        return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_search.failureMessage ?? '检索失败',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: AppFontSize.body, color: AppColors.red)),
            const SizedBox(height: AppSpacing.sm),
            OutlinedButton(
                onPressed: _search.retry, child: const Text('重试')),
          ]),
        );
      case CandidateSearchStatus.ready:
        if (_search.entries.isEmpty) {
          return const Center(
              child: Text('没有搜到候选。换个标签组合或描述再试',
                  style: TextStyle(
                      fontSize: AppFontSize.body,
                      color: AppColors.textTertiary)));
        }
        return Column(children: [
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(AppSpacing.lg),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 168,
                mainAxisSpacing: AppSpacing.md,
                crossAxisSpacing: AppSpacing.md,
                childAspectRatio: 0.62,
              ),
              itemCount: _search.entries.length,
              itemBuilder: (context, i) => _card(_search.entries[i]),
            ),
          ),
          _pager(),
        ]);
    }
  }

  Widget _pager() {
    if (_search.pageCount <= 1) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: _search.hasPrevPage ? _search.prevPage : null,
            iconSize: 14,
            icon: const Icon(Icons.chevron_left)),
        Text('${_search.page} / ${_search.pageCount} 页 · 共 ${_search.total} 条',
            style: const TextStyle(
                fontSize: AppFontSize.caption, color: AppColors.textTertiary)),
        IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: _search.hasNextPage ? _search.nextPage : null,
            iconSize: 14,
            icon: const Icon(Icons.chevron_right)),
      ]),
    );
  }

  Widget _card(CandidateEntry entry) {
    final m = entry.material;
    final pickedIndex = _picked.indexWhere((s) => s.materialId == m.id);
    final picked = pickedIndex >= 0;
    final usedByLine = widget.usedBy[m.id];
    final usedElsewhere = usedByLine != null && usedByLine != widget.lineIndex;
    return InkWell(
      key: ValueKey('shot-candidate-${m.id}'),
      onTap: () => _toggle(entry),
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
              color: picked ? AppColors.accentBlue : AppColors.border,
              width: picked ? 1.5 : 1),
          color: AppColors.surfaceRaised,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: Stack(fit: StackFit.expand, children: [
              m.thumbnailUrl == null
                  ? Container(
                      color: Colors.black,
                      child: const Icon(Icons.image_not_supported_outlined,
                          size: 18, color: AppColors.textTertiary))
                  : Image.network(m.thumbnailUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                          color: Colors.black,
                          child: const Icon(Icons.broken_image_outlined,
                              size: 18, color: AppColors.textTertiary))),
              if (entry.spec != null)
                Positioned(
                  right: 4,
                  bottom: 4,
                  child: _badge(
                      '${(entry.spec!.durationMs / 1000).toStringAsFixed(1)}s',
                      Colors.black.withValues(alpha: 0.65),
                      Colors.white),
                ),
              if (usedElsewhere)
                Positioned(
                  left: 4,
                  top: 4,
                  child: _badge('第 ${usedByLine + 1} 行在用',
                      AppColors.orange.withValues(alpha: 0.85), Colors.black),
                ),
              Positioned(
                left: 4,
                bottom: 4,
                child: Tooltip(
                  message: '找相似画面',
                  child: InkWell(
                    key: ValueKey('shot-similar-${m.id}'),
                    onTap: () => _searchSimilar(entry),
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.65),
                          borderRadius: BorderRadius.circular(4)),
                      child: const Icon(Icons.image_search,
                          size: 12, color: Colors.white),
                    ),
                  ),
                ),
              ),
              if (picked)
                Positioned(
                  right: 4,
                  top: 4,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: const BoxDecoration(
                        color: AppColors.accentBlue, shape: BoxShape.circle),
                    alignment: Alignment.center,
                    child: Text('${pickedIndex + 1}',
                        style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: Colors.white)),
                  ),
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.all(6),
            child: Text(m.voiceover.isNotEmpty ? m.voiceover : m.sceneDescription,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: AppFontSize.micro,
                    color: AppColors.textSecondary,
                    height: 1.35)),
          ),
        ]),
      ),
    );
  }

  Widget _badge(String text, Color bg, Color fg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
            color: bg, borderRadius: BorderRadius.circular(4)),
        child: Text(text,
            style: TextStyle(
                fontSize: 9, fontWeight: FontWeight.w600, color: fg)),
      );

  void _toggle(CandidateEntry entry) {
    final m = entry.material;
    setState(() {
      final i = _picked.indexWhere((s) => s.materialId == m.id);
      if (i >= 0) {
        _picked.removeAt(i);
      } else {
        _picked.add(LineShot(
          materialId: m.id,
          name: m.name,
          voiceover: m.voiceover,
          sceneDescription: m.sceneDescription,
          thumbnailUrl: m.thumbnailUrl,
          fileKey: m.fileKey,
          durationMs: entry.spec?.durationMs,
        ));
      }
    });
  }

  Widget _footer() => Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xl, vertical: AppSpacing.md),
        child: Row(children: [
          Text(
              _picked.isEmpty
                  ? '点候选卡片挑镜头，按点选顺序排'
                  : '已选 ${_picked.length} 个镜头（按点选顺序排）',
              style: const TextStyle(
                  fontSize: AppFontSize.caption,
                  color: AppColors.textSecondary)),
          const Spacer(),
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消')),
          const SizedBox(width: AppSpacing.sm),
          FilledButton(
            key: const ValueKey('shots-confirm'),
            onPressed: () => Navigator.of(context).pop(FindShotsResult(
                shots: List<LineShot>.from(_picked),
                tags: [
                  for (final t in _tags)
                    if (_enabledTags.contains(t)) t,
                ])),
            child: const Text('用这些镜头'),
          ),
        ]),
      );
}
