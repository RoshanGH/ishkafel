import 'dart:io';

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
import 'tag_picker.dart';

/// 检索维度（用户定的三个）：台词 / 画面描述 / 首帧找相似。
/// 标签与项目不是维度，是所有维度共用的外部约束
enum _SearchDim { voiceover, description, similar }

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

  /// 参考分镜（原子）的首帧缩略图路径；null = 还没抽出来
  String? Function(int segIndex)? refThumbOf,

  /// 参考视频的本地路径（原子「直接用原片这段」要它）
  String? refVideoPath,
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
        refThumbOf: refThumbOf,
        refVideoPath: refVideoPath,
      ),
    );

class _FindShotsSheet extends StatefulWidget {
  final ShotSearchServices services;
  final LineTagger? tagger;
  final RenewTask task;
  final int lineIndex;
  final ScriptLine line;
  final Map<int, int> usedBy;
  final String? Function(int segIndex)? refThumbOf;
  final String? refVideoPath;

  const _FindShotsSheet({
    required this.services,
    required this.tagger,
    required this.task,
    required this.lineIndex,
    required this.line,
    required this.usedBy,
    this.refThumbOf,
    this.refVideoPath,
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

  /// 台词维度的检索词（预填本行台词——参考片这一句在说什么）
  late final TextEditingController _voiceoverKw =
      TextEditingController(text: widget.line.text.trim());

  /// 画面描述维度的检索词（人来描述想要的画面）
  final TextEditingController _descKw = TextEditingController();

  /// 检索用的标签（预填行标签；勾选状态就在这里维护）。
  /// 标签不是一个独立维度，是**所有维度共用的外部约束**
  late final List<String> _tags = [...widget.line.tags];
  late final Set<String> _enabledTags = {...widget.line.tags};

  /// 标签名 → miaoa 标签 id。打开面板时按任务的分子标签组拉一次；
  /// 从标签选择器新加的标签会把解析好的 id 补进来
  Map<String, int>? _tagIds;
  String? _tagIdsError;

  /// 当前检索维度
  _SearchDim _dim = _SearchDim.voiceover;
  bool _tagging = false;

  /// 找相似的查询帧（候选卡「找相似」发起）；null = 还没有目标
  String? _similarToName;
  String? _similarFileKey;

  /// 当前选中的参考原子（参考分镜下标）；null = 整句。
  /// 点选哪个原子，检索条件就切到那个原子——它那个时段说的话当检索词
  int? _refSeg;

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
    // 默认按台词搜——检索依据就是参考片这一句的 ASR 台词，行标签作约束
    await _runSearch();
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

  /// 统一检索入口：当前维度 + 标签约束（约束贴在每一种维度上）。
  /// 维度输入为空而约束非空时，退化为纯标签筛
  Future<void> _runSearch() async {
    final ids = _enabledTagIds;
    switch (_dim) {
      case _SearchDim.voiceover:
        final kw = _voiceoverKw.text.trim();
        if (kw.isEmpty && ids.isEmpty) return;
        await (kw.isEmpty
            ? _search.searchByTags(tagIds: ids)
            : _search.searchByVoiceover(kw, tagIds: ids));
      case _SearchDim.description:
        final kw = _descKw.text.trim();
        if (kw.isEmpty && ids.isEmpty) return;
        await (kw.isEmpty
            ? _search.searchByTags(tagIds: ids)
            : _search.searchByDescription(kw, tagIds: ids));
      case _SearchDim.similar:
        final key = _similarFileKey;
        if (key == null) return;
        await _search.searchByImage(key, tagIds: ids);
    }
  }

  /// 找相似：拿一条候选的首帧当查询帧，切到「找相似」维度
  Future<void> _searchSimilar(CandidateEntry entry) async {
    final fileKey = entry.material.fileKey;
    if (fileKey == null || fileKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('这条素材没有可用的查询帧，搜不了相似。')));
      return;
    }
    final m = entry.material;
    setState(() {
      _dim = _SearchDim.similar;
      _similarToName = m.voiceover.isNotEmpty ? m.voiceover : m.name;
      _similarFileKey = fileKey;
    });
    await _runSearch();
  }

  /// 打开标签选择器：从妙啊标签体系里搜索、点选、替换约束标签
  Future<void> _pickTags() async {
    final picked = await showTagPicker(
      context,
      tags: widget.services.tags,
      selected: [
        for (final t in _tags)
          if (_enabledTags.contains(t)) t,
      ],
      preferredGroupIds: {for (final g in widget.task.unitTagGroups) g.id},
    );
    if (picked == null || !mounted) return;
    setState(() {
      _tags
        ..clear()
        ..addAll(picked.map((t) => t.name));
      _enabledTags
        ..clear()
        ..addAll(picked.map((t) => t.name));
      for (final t in picked) {
        if (t.id != null) (_tagIds ??= {})[t.name] = t.id!;
      }
    });
    await _runSearch();
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
    _voiceoverKw.dispose();
    _descKw.dispose();
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
          if ((widget.line.reference?.segments.length ?? 0) > 0) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
              child: _refAtomBar(),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
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

  /// 参考原子条：这一句在原片里的各个参考分镜（原子）。
  /// 点选一个原子 → 检索词切成「这个原子时段说的话」，一个原子一个
  /// 原子地找替代品；再点一下取消回到整句。原子上还能「直接用原片」
  Widget _refAtomBar() {
    final ref = widget.line.reference!;
    final segments = ref.segments;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(top: 20),
        child: Text('参考',
            style: const TextStyle(
                fontSize: AppFontSize.caption,
                color: AppColors.textTertiary)),
      ),
      const SizedBox(width: AppSpacing.sm),
      Expanded(
        child: SizedBox(
          height: 96,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: segments.length,
            separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.xs),
            itemBuilder: (context, k) => _refAtomCard(k, segments[k]),
          ),
        ),
      ),
    ]);
  }

  Widget _refAtomCard(int k, (int, int) seg) {
    final selected = _refSeg == k;
    final thumb = widget.refThumbOf?.call(k);
    final text = widget.line.reference!
        .segmentText(k, widget.line.text.trim());
    return InkWell(
      key: ValueKey('shots-ref-atom-$k'),
      onTap: () {
        setState(() {
          if (selected) {
            _refSeg = null;
            _voiceoverKw.text = widget.line.text.trim();
          } else {
            _refSeg = k;
            _dim = _SearchDim.voiceover;
            _voiceoverKw.text = text;
          }
        });
        _runSearch();
      },
      borderRadius: BorderRadius.circular(AppRadius.sm),
      hoverColor: AppColors.hover,
      child: Container(
        width: 168,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(
              color: selected ? AppColors.accentBlue : AppColors.border,
              width: selected ? 1.4 : 1),
          color: selected
              ? AppColors.accentBlue.withValues(alpha: 0.08)
              : Colors.transparent,
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              width: 48,
              child: thumb != null
                  ? Image.file(File(thumb), fit: BoxFit.cover)
                  : Container(
                      color: Colors.black,
                      child: const Icon(Icons.hourglass_empty,
                          size: 11, color: AppColors.textTertiary)),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('第 ${k + 1} 镜 · ${_fmtS(seg.$2 - seg.$1)}',
                      style: TextStyle(
                          fontSize: AppFontSize.micro,
                          fontWeight: FontWeight.w600,
                          color: selected
                              ? AppColors.accentBlueLight
                              : AppColors.textSecondary)),
                  const SizedBox(height: 2),
                  Expanded(
                    child: Text(text,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: AppFontSize.micro,
                            height: 1.35,
                            color: AppColors.textTertiary)),
                  ),
                  InkWell(
                    key: ValueKey('shots-use-ref-$k'),
                    onTap: widget.refVideoPath == null
                        ? null
                        : () => _useRefAtom(k, seg),
                    child: const Text('直接用原片这段',
                        style: TextStyle(
                            fontSize: AppFontSize.micro,
                            fontWeight: FontWeight.w600,
                            color: AppColors.accentBlueLight)),
                  ),
                ]),
          ),
        ]),
      ),
    );
  }

  /// 原子「直接用原片这段」：本地源镜头加入已选序列（负数占位 id，
  /// 不参与下载与防撞车——与行带上的老「用它」同一套规矩）
  void _useRefAtom(int k, (int, int) seg) {
    final video = widget.refVideoPath!;
    if (_picked.any(
        (s) => s.localSource == video && s.trimStartMs == seg.$1)) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('这段原片画面已经在已选里了。')));
      return;
    }
    setState(() => _picked.add(LineShot(
          materialId: -(seg.$1 + 1),
          name: '参考画面',
          sceneDescription: '参考片 ${_fmtS(seg.$1)}~${_fmtS(seg.$2)} 处',
          durationMs: seg.$2 - seg.$1,
          localSource: video,
          trimStartMs: seg.$1,
        )));
  }

  static String _fmtS(int ms) => '${(ms / 1000).toStringAsFixed(1)}s';

  Widget _searchBar() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // 三个检索维度（可切）；标签在下面一行，是所有维度共用的约束
      Row(children: [
        _modePill('按台词', _dim == _SearchDim.voiceover, () {
          setState(() => _dim = _SearchDim.voiceover);
          _runSearch();
        }, key: const ValueKey('shots-dim-voiceover')),
        const SizedBox(width: AppSpacing.xs),
        _modePill('按画面描述', _dim == _SearchDim.description, () {
          setState(() => _dim = _SearchDim.description);
          if (_descKw.text.trim().isNotEmpty) _runSearch();
        }, key: const ValueKey('shots-dim-description')),
        const SizedBox(width: AppSpacing.xs),
        _modePill('找相似', _dim == _SearchDim.similar, () {
          if (_similarFileKey == null) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('先在下面的候选卡上点「找相似」，以那条的首帧为查询帧。')));
            return;
          }
          setState(() => _dim = _SearchDim.similar);
          _runSearch();
        }, key: const ValueKey('shots-dim-similar')),
        const Spacer(),
        if (widget.tagger != null)
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
      switch (_dim) {
        _SearchDim.voiceover => _keywordField(
            _voiceoverKw, '这一句台词说什么，就找说同类话的分镜',
            key: const ValueKey('shots-keyword-voiceover')),
        _SearchDim.description => _keywordField(
            _descKw, '描述想要的画面，例如「厨房喷洒清洁剂」',
            key: const ValueKey('shots-keyword-desc')),
        _SearchDim.similar => _similarBar(),
      },
      const SizedBox(height: AppSpacing.sm),
      _constraintChips(),
    ]);
  }

  /// 找相似维度的当前查询帧说明
  Widget _similarBar() => Row(children: [
        const Icon(Icons.image_search, size: 14, color: AppColors.textTertiary),
        const SizedBox(width: AppSpacing.xs),
        Expanded(
          child: Text('以「${_similarToName ?? ''}」的首帧找相似画面',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: AppFontSize.caption,
                  color: AppColors.textSecondary)),
        ),
      ]);

  /// 标签约束条：所有维度共用。点选启停；「+ 标签」打开词表选择器
  Widget _constraintChips() {
    final error = _tagIdsError;
    return Wrap(
        spacing: AppSpacing.xs,
        runSpacing: AppSpacing.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(_tags.isEmpty ? '标签约束：不限' : '标签约束：',
              style: const TextStyle(
                  fontSize: AppFontSize.caption, color: AppColors.textTertiary)),
          for (final tag in _tags)
            FilterChip(
              key: ValueKey('shot-tag-$tag'),
              label: Text(tag,
                  style: const TextStyle(fontSize: AppFontSize.caption)),
              selected: _enabledTags.contains(tag),
              visualDensity: VisualDensity.compact,
              onSelected: (on) {
                setState(
                    () => on ? _enabledTags.add(tag) : _enabledTags.remove(tag));
                _runSearch();
              },
            ),
          ActionChip(
            key: const ValueKey('shots-pick-tags'),
            avatar: const Icon(Icons.add, size: 13),
            label: const Text('标签',
                style: TextStyle(fontSize: AppFontSize.caption)),
            visualDensity: VisualDensity.compact,
            onPressed: _pickTags,
          ),
          if (error != null)
            Text(error,
                style: const TextStyle(
                    fontSize: AppFontSize.micro, color: AppColors.orange)),
        ]);
  }

  Widget _keywordField(TextEditingController controller, String hint,
          {Key? key}) =>
      Row(children: [
        Expanded(
          child: TextField(
            key: key,
            controller: controller,
            style: const TextStyle(fontSize: AppFontSize.body),
            decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 15),
                hintText: hint),
            onSubmitted: (_) => _runSearch(),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        FilledButton(
            key: const ValueKey('shots-search'),
            onPressed: _runSearch,
            child: const Text('搜索')),
      ]);

  Widget _modePill(String label, bool selected, VoidCallback onTap,
          {Key? key}) =>
      InkWell(
        key: key,
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
                fontSize: AppFontSize.micro, fontWeight: FontWeight.w600, color: fg)),
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
