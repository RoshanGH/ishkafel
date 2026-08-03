import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_typography.dart';
import '../../core/editing/segmentation_editor_controller.dart';
import '../../core/models/semantic_unit.dart';
import 'inspector_widgets.dart';
import 'tag_trace_section.dart';

/// 把毫秒时间戳格式化为 `mm:ss.ff`（ff 为两位帧号，前补 0）。
///
/// 帧号先把 ms 换算为总帧数再四舍五入取整，而不是直接对 `ms % 1000` 做浮点
/// 运算截断：例如 70033ms/30fps 精确对应第 2101 帧（70.033*30=2100.99，
/// 四舍五入为 2101），落在第 70 秒的第 1 帧上，若直接对毫秒余数取整会因浮
/// 点误差把这一帧算漏、显示成 00 帧。
///
/// `fps.round()` 用作 mm:ss 的秒数除数是显示层的可接受近似：非整数帧率
/// （如 29.97）下会有亚帧级漂移，但不会导致 ff 达到/超过 fpsRound（帧号
/// 始终落在 [0, fpsRound) 内），因此只影响显示，不影响编辑运算的帧精度
/// （编辑运算走 SegmentationEditOps.frameMs，独立于这里的显示格式化）。
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
///
/// 纯展示型辅助组件（卡片/步进按钮/标签 chips 等）拆在 [inspector_widgets.dart]
/// 里，本文件只负责三态判断、与 controller 的数据/事件绑定。
class InspectorPanel extends StatefulWidget {
  final SegmentationEditorController controller;
  final double fps;

  /// 「在游标处拆分」的实际拆分时机（当前播放头位置）由外部（审片台页面）
  /// 决定，本面板只负责转发点击事件。
  final VoidCallback? onSplitAtPlayhead;

  /// 只读回看模式（评审 Important 1）：true 时步进按钮、台词输入框、拆分/
  /// 并入按钮全部禁用——已确认（picking/exported）的切分结构不允许被
  /// 静默改写。默认 false（编辑态，行为与此前一致）。
  final bool readOnly;

  const InspectorPanel({
    super.key,
    required this.controller,
    required this.fps,
    this.onSplitAtPlayhead,
    this.readOnly = false,
  });

  @override
  State<InspectorPanel> createState() => _InspectorPanelState();
}

class _InspectorPanelState extends State<InspectorPanel> {
  final _transcriptController = TextEditingController();

  /// 台词 TextField 专用 FocusNode：聚焦时开启编辑会话、失焦时结束（评审
  /// Important 3），使聚焦期间连续多次 updateTranscript（逐击键入）合并
  /// 为一条 undo 记录，而不是每个字符都单独入栈。
  final _transcriptFocusNode = FocusNode(debugLabel: 'InspectorTranscript');

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _transcriptFocusNode.addListener(_onTranscriptFocusChanged);
    _syncTranscript();
  }

  void _onTranscriptFocusChanged() {
    if (_transcriptFocusNode.hasFocus) {
      widget.controller.beginTextSession();
    } else {
      widget.controller.endTextSession();
    }
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
    _transcriptFocusNode.removeListener(_onTranscriptFocusChanged);
    // 兜底：若卸载发生在台词编辑会话进行中（如切换选中对象导致本面板随之
    // 重建/卸载而非正常失焦），必须显式结束会话，否则 controller 的会话
    // 快照永久非空、此后所有编辑都会静默跳过 undo 入栈。该方法本身幂等。
    widget.controller.endTextSession();
    _transcriptController.dispose();
    _transcriptFocusNode.dispose();
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
        style: TextStyle(color: AppColors.textTertiary, fontSize: AppFontSize.body),
      ),
    );
  }

  Widget _buildUnitInspector(int unitIndex) {
    final units = widget.controller.units;
    if (unitIndex < 0 || unitIndex >= units.length) return _buildPlaceholder();
    final unit = units[unitIndex];
    // 首单元没有前一个单元可合并边界，末单元没有后一个单元可合并边界；
    // 只读模式下一律禁用（回看不允许改写已确认的结构）。
    final canNudgeStart = unitIndex > 0 && !widget.readOnly;
    final canNudgeEnd = unitIndex < units.length - 1 && !widget.readOnly;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          inspectorTitle('台词语义单元 — U${unit.index + 1}'),
          const SizedBox(height: 10),
          inspectorCard([
            inspectorTimeRow(
              label: '开始',
              valueText: formatTimecode(unit.startMs, widget.fps),
              minusKey: const Key('inspector-start-minus'),
              plusKey: const Key('inspector-start-plus'),
              minusEnabled: canNudgeStart,
              plusEnabled: canNudgeStart,
              onMinus: () => widget.controller
                  .nudgeSelectedEdge(startEdge: true, frames: -1),
              onPlus: () => widget.controller
                  .nudgeSelectedEdge(startEdge: true, frames: 1),
            ),
            inspectorTimeRow(
              label: '结束',
              valueText: formatTimecode(unit.endMs, widget.fps),
              minusKey: const Key('inspector-end-minus'),
              plusKey: const Key('inspector-end-plus'),
              minusEnabled: canNudgeEnd,
              plusEnabled: canNudgeEnd,
              onMinus: () => widget.controller
                  .nudgeSelectedEdge(startEdge: false, frames: -1),
              onPlus: () => widget.controller
                  .nudgeSelectedEdge(startEdge: false, frames: 1),
            ),
            inspectorInfoRow(
                '时长', '${(unit.durationMs / 1000).toStringAsFixed(2)}s'),
            inspectorInfoRow('镜头数', '${unit.shots.length}'),
          ]),
          const SizedBox(height: 10),
          TagTraceSection(
            title: '台词语义单元标签',
            tags: unit.tags,
            tagsStale: unit.tagsStale,
            trace: unit.trace,
          ),
          const SizedBox(height: 10),
          inspectorCard([
            // 回看模式下台词框是禁用的，标题必须如实反映，不能继续声称可编辑
            inspectorLabel(
                widget.readOnly ? '单元台词（只读）' : '单元台词（可编辑）'),
            const SizedBox(height: 6),
            _transcriptField(unitIndex),
          ]),
          const SizedBox(height: 10),
          inspectorActionsRow(
            splitLabel: '✂ 在游标处拆分单元',
            mergeLabel: '⇧ 并入上一单元',
            onSplit: widget.readOnly
                ? null
                : () => widget.onSplitAtPlayhead?.call(),
            onMerge: widget.readOnly
                ? null
                : widget.controller.mergeSelectedWithPrevious,
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
    // 单元内首/末镜头同理没有对应方向的相邻边界可调；只读模式下同样禁用。
    final canNudgeStart = shotIndex > 0 && !widget.readOnly;
    final canNudgeEnd = shotIndex < shots.length - 1 && !widget.readOnly;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          inspectorTitle('视觉镜头 — U${unit.index + 1} · S${shotIndex + 1}'),
          const SizedBox(height: 10),
          inspectorCard([
            inspectorInfoRow('所属单元',
                'U${unit.index + 1} · ${(unit.durationMs / 1000).toStringAsFixed(2)}s'),
            inspectorTimeRow(
              label: '镜头开始',
              valueText: formatTimecode(shot.startMs, widget.fps),
              minusKey: const Key('inspector-start-minus'),
              plusKey: const Key('inspector-start-plus'),
              minusEnabled: canNudgeStart,
              plusEnabled: canNudgeStart,
              onMinus: () => widget.controller
                  .nudgeSelectedEdge(startEdge: true, frames: -1),
              onPlus: () => widget.controller
                  .nudgeSelectedEdge(startEdge: true, frames: 1),
            ),
            inspectorTimeRow(
              label: '镜头结束',
              valueText: formatTimecode(shot.endMs, widget.fps),
              minusKey: const Key('inspector-end-minus'),
              plusKey: const Key('inspector-end-plus'),
              minusEnabled: canNudgeEnd,
              plusEnabled: canNudgeEnd,
              onMinus: () => widget.controller
                  .nudgeSelectedEdge(startEdge: false, frames: -1),
              onPlus: () => widget.controller
                  .nudgeSelectedEdge(startEdge: false, frames: 1),
            ),
            inspectorInfoRow(
                '时长', '${(shot.durationMs / 1000).toStringAsFixed(2)}s'),
          ]),
          const SizedBox(height: 10),
          TagTraceSection(
            title: '视觉镜头标签',
            tags: shot.tags,
            tagsStale: shot.tagsStale,
            description: shot.description,
            trace: shot.trace,
          ),
          const SizedBox(height: 10),
          inspectorActionsRow(
            splitLabel: '✂ 在游标处拆分镜头',
            mergeLabel: '⇧ 并入前一镜头',
            onSplit: widget.readOnly
                ? null
                : () => widget.onSplitAtPlayhead?.call(),
            onMerge: widget.readOnly
                ? null
                : widget.controller.mergeSelectedWithPrevious,
          ),
        ],
      ),
    );
  }

  Widget _transcriptField(int unitIndex) {
    return TextField(
      key: const Key('inspector-transcript-field'),
      controller: _transcriptController,
      focusNode: _transcriptFocusNode,
      enabled: !widget.readOnly,
      maxLines: null,
      minLines: 2,
      style: const TextStyle(color: AppColors.textPrimary, fontSize: AppFontSize.body),
      decoration: const InputDecoration(
        isDense: true,
        border: InputBorder.none,
      ),
      onChanged: (text) => widget.controller.updateTranscript(unitIndex, text),
    );
  }
}
