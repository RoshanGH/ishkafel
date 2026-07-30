import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../core/editing/segmentation_editor_controller.dart';
import '../../core/models/semantic_unit.dart';

/// 把毫秒时间戳格式化为 `mm:ss.ff`（ff 为两位帧号，前补 0）。
///
/// 帧号先把 ms 换算为总帧数再四舍五入取整，而不是直接对 `ms % 1000` 做浮点
/// 运算截断：例如 70033ms/30fps 精确对应第 2101 帧（70.033*30=2100.99，
/// 四舍五入为 2101），落在第 70 秒的第 1 帧上，若直接对毫秒余数取整会因浮
/// 点误差把这一帧算漏、显示成 00 帧。
String formatTimecode(int ms, double fps) {
  final fpsRound = fps.round();
  final totalFrames = (ms * fps / 1000).round();
  final totalSeconds = totalFrames ~/ fpsRound;
  final ff = totalFrames % fpsRound;
  final mm = totalSeconds ~/ 60;
  final ss = totalSeconds % 60;
  return '${_pad2(mm)}:${_pad2(ss)}.${_pad2(ff)}';
}

String _pad2(int n) => n.toString().padLeft(2, '0');

/// 属性检查器：右栏，跟随 [SegmentationEditorController.selection] 三态渲染
/// ——选中单元 / 选中镜头 / 无选中占位。
class InspectorPanel extends StatefulWidget {
  final SegmentationEditorController controller;
  final double fps;

  /// 「在游标处拆分」的实际拆分时机（当前播放头位置）由外部（审片台页面）
  /// 决定，本面板只负责转发点击事件。
  final VoidCallback? onSplitAtPlayhead;

  const InspectorPanel({
    super.key,
    required this.controller,
    required this.fps,
    this.onSplitAtPlayhead,
  });

  @override
  State<InspectorPanel> createState() => _InspectorPanelState();
}

class _InspectorPanelState extends State<InspectorPanel> {
  final _transcriptController = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _syncTranscript();
  }

  @override
  void didUpdateWidget(covariant InspectorPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
    _syncTranscript();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _transcriptController.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    _syncTranscript();
    setState(() {});
  }

  /// 仅在受控单元的台词与当前文本框内容不一致时才写回，避免用户正在输入时
  /// 因 notifyListeners 触发的 setState 把光标强制拉回文本末尾。
  void _syncTranscript() {
    final text = _selectedUnit()?.transcript ?? '';
    if (_transcriptController.text != text) {
      _transcriptController.text = text;
    }
  }

  SemanticUnit? _selectedUnit() {
    final sel = widget.controller.selection;
    final units = widget.controller.units;
    if (sel == null || sel.unitIndex < 0 || sel.unitIndex >= units.length) {
      return null;
    }
    return units[sel.unitIndex];
  }

  @override
  Widget build(BuildContext context) {
    final selection = widget.controller.selection;
    final Widget body;
    if (selection == null) {
      body = _buildPlaceholder();
    } else if (selection.shotIndex == null) {
      body = _buildUnitInspector(selection.unitIndex);
    } else {
      body = _buildShotInspector(selection.unitIndex, selection.shotIndex!);
    }
    return Container(
      color: AppColors.surfaceRaised,
      padding: const EdgeInsets.all(14),
      child: body,
    );
  }

  Widget _buildPlaceholder() {
    return const Center(
      child: Text(
        '未选中任何单元或镜头\n点击左侧列表或时间线查看详情',
        textAlign: TextAlign.center,
        style: TextStyle(color: AppColors.textTertiary, fontSize: 12),
      ),
    );
  }

  Widget _buildUnitInspector(int unitIndex) {
    final units = widget.controller.units;
    if (unitIndex < 0 || unitIndex >= units.length) return _buildPlaceholder();
    final unit = units[unitIndex];

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _title('单元详情 — U${unit.index + 1}'),
          const SizedBox(height: 10),
          _card([
            _timeRow(
              label: '开始',
              ms: unit.startMs,
              keyPrefix: 'start',
              onMinus: () => widget.controller
                  .nudgeSelectedEdge(startEdge: true, frames: -1),
              onPlus: () => widget.controller
                  .nudgeSelectedEdge(startEdge: true, frames: 1),
            ),
            _timeRow(
              label: '结束',
              ms: unit.endMs,
              keyPrefix: 'end',
              onMinus: () => widget.controller
                  .nudgeSelectedEdge(startEdge: false, frames: -1),
              onPlus: () => widget.controller
                  .nudgeSelectedEdge(startEdge: false, frames: 1),
            ),
            _infoRow('时长', '${(unit.durationMs / 1000).toStringAsFixed(2)}s'),
            _infoRow('镜头数', '${unit.shots.length}'),
          ]),
          const SizedBox(height: 10),
          _card([
            _label('标签'),
            const SizedBox(height: 6),
            _tagChips(unit.tags),
          ]),
          const SizedBox(height: 10),
          _card([
            _label('单元台词（可编辑）'),
            const SizedBox(height: 6),
            _transcriptField(unitIndex),
          ]),
          const SizedBox(height: 10),
          _actionsRow(
            mergeLabel: '⇧ 并入上一单元',
            onMerge: widget.controller.mergeSelectedWithPrevious,
          ),
        ],
      ),
    );
  }

  Widget _buildShotInspector(int unitIndex, int shotIndex) {
    final units = widget.controller.units;
    if (unitIndex < 0 || unitIndex >= units.length) return _buildPlaceholder();
    final unit = units[unitIndex];
    final shots = unit.shots;
    if (shotIndex < 0 || shotIndex >= shots.length) return _buildPlaceholder();
    final shot = shots[shotIndex];

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _title('镜头详情 — U${unit.index + 1} · S${shotIndex + 1}'),
          const SizedBox(height: 10),
          _card([
            _infoRow('所属单元',
                'U${unit.index + 1} · ${(unit.durationMs / 1000).toStringAsFixed(2)}s'),
            _timeRow(
              label: '镜头开始',
              ms: shot.startMs,
              keyPrefix: 'start',
              onMinus: () => widget.controller
                  .nudgeSelectedEdge(startEdge: true, frames: -1),
              onPlus: () => widget.controller
                  .nudgeSelectedEdge(startEdge: true, frames: 1),
            ),
            _timeRow(
              label: '镜头结束',
              ms: shot.endMs,
              keyPrefix: 'end',
              onMinus: () => widget.controller
                  .nudgeSelectedEdge(startEdge: false, frames: -1),
              onPlus: () => widget.controller
                  .nudgeSelectedEdge(startEdge: false, frames: 1),
            ),
            _infoRow('时长', '${(shot.durationMs / 1000).toStringAsFixed(2)}s'),
          ]),
          const SizedBox(height: 10),
          _card([
            _label('镜头标签'),
            const SizedBox(height: 6),
            _tagChips(shot.tags),
          ]),
          const SizedBox(height: 10),
          _actionsRow(
            mergeLabel: '⇧ 并入前一镜头',
            onMerge: widget.controller.mergeSelectedWithPrevious,
          ),
        ],
      ),
    );
  }

  Widget _transcriptField(int unitIndex) {
    return TextField(
      key: const Key('inspector-transcript-field'),
      controller: _transcriptController,
      maxLines: null,
      minLines: 2,
      style: const TextStyle(color: AppColors.textPrimary, fontSize: 12),
      decoration: const InputDecoration(
        isDense: true,
        border: InputBorder.none,
      ),
      onChanged: (text) => widget.controller.updateTranscript(unitIndex, text),
    );
  }

  Widget _title(String text) => Text(
        text,
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
        ),
      );

  Widget _label(String text) => Text(
        text,
        style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
      );

  Widget _card(List<Widget> children) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surfaceCard,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            children[i],
          ],
        ]),
      );

  Widget _infoRow(String label, String value) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _label(label),
          Text(value,
              style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 12,
                  fontFeatures: [FontFeature.tabularFigures()])),
        ],
      );

  Widget _timeRow({
    required String label,
    required int ms,
    required String keyPrefix,
    required VoidCallback onMinus,
    required VoidCallback onPlus,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _label(label),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _stepButton(Key('inspector-$keyPrefix-minus'), '−', onMinus),
              const SizedBox(width: 6),
              Text(
                formatTimecode(ms, widget.fps),
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 11.5,
                    fontFeatures: [FontFeature.tabularFigures()]),
              ),
              const SizedBox(width: 6),
              _stepButton(Key('inspector-$keyPrefix-plus'), '＋', onPlus),
            ],
          ),
        ),
      ],
    );
  }

  Widget _stepButton(Key key, String glyph, VoidCallback onTap) {
    return InkWell(
      key: key,
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Text(glyph,
            style: const TextStyle(color: AppColors.textTertiary, fontSize: 13)),
      ),
    );
  }

  Widget _tagChips(List<String> tags) {
    if (tags.isEmpty) {
      return const Text('无标签',
          style: TextStyle(color: AppColors.textTertiary, fontSize: 11));
    }
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: tags
          .map((t) => Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.accentBlue.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(t,
                    style: const TextStyle(
                        color: Color(0xFF64A8FF), fontSize: 10.5)),
              ))
          .toList(growable: false),
    );
  }

  Widget _actionsRow({
    required String mergeLabel,
    required VoidCallback onMerge,
  }) {
    return Row(
      children: [
        Expanded(
          child: _actionButton(
            key: const Key('inspector-split-btn'),
            label: '✂ 在游标处拆分',
            onTap: () => widget.onSplitAtPlayhead?.call(),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _actionButton(
            key: const Key('inspector-merge-btn'),
            label: mergeLabel,
            onTap: onMerge,
          ),
        ),
      ],
    );
  }

  Widget _actionButton({
    required Key key,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      key: key,
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.surfaceCard,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label,
            style:
                const TextStyle(color: AppColors.textPrimary, fontSize: 12)),
      ),
    );
  }
}
