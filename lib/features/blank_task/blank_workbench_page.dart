import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../core/editing/blank_unit_ops.dart';
import '../../core/editing/segmentation_editor_controller.dart';
import '../../core/models/renew_task.dart';
import '../../core/models/semantic_unit.dart';
import '../../core/replacement/picked_material.dart';
import '../../core/replacement/replacement_plan.dart';
import '../tasks/task_list_controller.dart';
import '../workbench/candidate_tab.dart';
import 'blank_unit_list.dart';
import 'blank_unit_tag_editor.dart';

/// 空白任务的工作台：没有原片，分子一个个排出来，标签手填，素材按标签搜。
///
/// **为什么另起一页而不是复用翻新工作台**：那一页的一切都建立在「有一条固定
/// 长度的原片」之上——切分、合并、拖边界、镜头层、按帧对齐、undo 栈里存的都是
/// 「同一条时间轴上的不同切法」。空白任务里这些操作一个都不成立（没有原始
/// 画面，"只换其中一个镜头"没有意义），硬塞进去等于在那一页里到处加
/// `if (isBlank)`。
///
/// 复用的是真正共用的东西：候选素材面板（[CandidateTab]）、替换方案模型、
/// 落地记录、导出。那几块本来就跟"有没有原片"无关。
class BlankWorkbenchPage extends ConsumerStatefulWidget {
  final RenewTask task;

  const BlankWorkbenchPage({super.key, required this.task});

  @override
  ConsumerState<BlankWorkbenchPage> createState() => _BlankWorkbenchPageState();
}

class _BlankWorkbenchPageState extends ConsumerState<BlankWorkbenchPage> {
  late RenewTask _task;
  late List<SemanticUnit> _units;
  List<UnitReplacement> _replacements = const [];
  List<PickedMaterial> _picked = const [];
  int? _selected;

  /// 给 [CandidateTab] 用。它跟随 editor 的 selection 决定"在给谁挑"，
  /// 而 durationMs 是 final——分子增删会改总长，所以每次都重建一个
  SegmentationEditorController? _editor;

  @override
  void initState() {
    super.initState();
    _task = widget.task;
    _units = _task.units ?? const [];
    _replacements = _task.replacements ?? const [];
    _picked = _task.pickedMaterials;
    if (_units.isNotEmpty) _selected = 0;
    _rebuildEditor();
  }

  @override
  void dispose() {
    _editor?.dispose();
    super.dispose();
  }

  /// 这个分子挑中的素材有多长；null 表示还没挑
  int? _durationOf(int index) {
    if (index >= _replacements.length) return null;
    final replacement = _replacements[index];
    if (replacement.mode != ReplacementMode.whole) return null;
    final id = replacement.wholePreviewId ??
        (replacement.wholeCandidateIds.isEmpty
            ? null
            : replacement.wholeCandidateIds.first);
    if (id == null) return null;
    for (final material in _picked) {
      if (material.id == id) return material.durationMs;
    }
    return null;
  }

  void _rebuildEditor() {
    final laid = BlankUnitOps.relayout(_units, durationOf: _durationOf);
    _units = laid;
    final total = laid.isEmpty ? BlankUnitOps.placeholderMs : laid.last.endMs;
    final previous = _editor;
    // 重建而不是改：durationMs 是 final，而分子增删、挑到素材都会改总长
    final next = SegmentationEditorController(
      initialUnits: laid,
      durationMs: total,
      // 空白任务没有原片帧率。30 只是内部坐标的刻度，不影响成片——
      // 成片规格跟素材走
      fps: 30,
      sentences: const [],
    );
    final selected = _selected;
    if (selected != null && selected < laid.length) {
      next.select(EditorSelection.unit(selected));
    }
    _editor = next;
    previous?.dispose();
  }

  Future<void> _save() async {
    final next = _task.copyWith(
      units: _units,
      replacements: _replacements,
      pickedMaterials: _picked,
      updatedAt: DateTime.now(),
    );
    _task = next;
    await ref.read(taskRepositoryProvider).save(next);
    await ref.read(taskListProvider.notifier).reload();
  }

  void _mutate(List<SemanticUnit> Function() change) {
    setState(() {
      _units = change();
      _rebuildEditor();
    });
    _save();
  }

  void _add() => _mutate(() {
        final next = BlankUnitOps.append(_units);
        _selected = next.length - 1;
        return next;
      });

  Future<void> _delete(int index) async {
    final filled = _durationOf(index) != null;
    if (filled) {
      // 删掉挑过素材的分子是破坏性的：那条素材的选择跟着没了
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('删掉 U${index + 1}？'),
          content: const Text('它已经挑好素材了。删掉之后这个选择也一并没了，撤不回来。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('删掉')),
          ],
        ),
      );
      if (ok != true) return;
    }
    _mutate(() {
      // 替换方案按下标记，分子删了它也要跟着删，否则后面的素材会串位
      if (index < _replacements.length) {
        _replacements = [..._replacements]..removeAt(index);
      }
      final next = BlankUnitOps.removeAt(_units, index);
      _selected = next.isEmpty ? null : index.clamp(0, next.length - 1);
      return next;
    });
  }

  void _reorder(int from, int to) => _mutate(() {
        if (from < _replacements.length && to < _replacements.length) {
          final moved = [..._replacements];
          moved.insert(to, moved.removeAt(from));
          _replacements = moved;
        }
        _selected = to;
        return BlankUnitOps.move(_units, from, to);
      });

  void _setTags(int index, List<String> tags) =>
      _mutate(() => BlankUnitOps.setTags(_units, index, tags));

  @override
  Widget build(BuildContext context) {
    final editor = _editor;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(_task.name),
        backgroundColor: AppColors.surface,
      ),
      body: editor == null
          ? const SizedBox.shrink()
          : Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 280,
                  child: BlankUnitList(
                    units: _units,
                    durationOf: _durationOf,
                    selectedIndex: _selected,
                    onSelect: (i) => setState(() {
                      _selected = i;
                      editor.select(EditorSelection.unit(i));
                    }),
                    onAdd: _add,
                    onDelete: _delete,
                    onReorder: _reorder,
                  ),
                ),
                const VerticalDivider(width: 1, color: AppColors.border),
                Expanded(child: _rightPane(editor)),
              ],
            ),
    );
  }

  Widget _rightPane(SegmentationEditorController editor) {
    final selected = _selected;
    if (selected == null || selected >= _units.length) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.xl),
          child: Text('左边加一个分子，选中它，就能在这里打标签、挑素材',
              style: TextStyle(color: AppColors.textTertiary)),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        BlankUnitTagEditor(
          key: ValueKey('blank-tags-$selected'),
          unitIndex: selected,
          tags: _units[selected].tags,
          tagGroups: _task.unitTagGroups,
          project: _task.project,
          onChanged: (tags) => _setTags(selected, tags),
        ),
        const Divider(height: 1, color: AppColors.border),
        Expanded(
          child: CandidateTab(
            editor: editor,
            unitTagGroups: _task.unitTagGroups,
            // 空白任务不分镜头，镜头那一层的标签组用不上
            shotTagGroups: const [],
            project: _task.project,
            initialReplacements: _replacements,
            pickedMaterials: _picked,
            onReplacementsChanged: (next) {
              setState(() {
                _replacements = next;
                _rebuildEditor();
              });
              _save();
            },
            onPickedMaterialsChanged: (next) {
              setState(() {
                _picked = next;
                _rebuildEditor();
              });
              _save();
            },
          ),
        ),
      ],
    );
  }
}
