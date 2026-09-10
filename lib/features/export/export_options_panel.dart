import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/export/export_spec.dart';

/// 导出选项。版式对齐剪映专业版：**一列「标签 + 下拉」**。
///
/// 码率选项是**具体数字**（按当前分辨率 × 帧率算出），档位名只是后缀注明
/// ——「推荐」到底是多少不该让人猜。「预计大小」跟着任何一项选择实时变。
class ExportOptionsPanel extends StatelessWidget {
  final ExportSpec spec;
  final ValueChanged<ExportSpec> onSpecChanged;

  /// 全部排列组合有多少条
  final int totalCombos;

  /// null = 全部导出；否则是「只挑这么多条差异最大的」
  final int? pickCount;
  final ValueChanged<int?> onPickCountChanged;

  /// 每条成片的时长（算预计大小用）。0 表示未知，那时不显示预计大小
  final int durationMs;

  final bool enabled;

  const ExportOptionsPanel({
    super.key,
    required this.spec,
    required this.onSpecChanged,
    required this.totalCombos,
    required this.pickCount,
    required this.onPickCountChanged,
    this.durationMs = 0,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('导出哪几条'),
          const SizedBox(height: AppSpacing.xs),
          _pickMode(),
          const SizedBox(height: AppSpacing.md),
          _label('画面规格'),
          const SizedBox(height: AppSpacing.xs),
          _row('分辨率', _resolution()),
          _row('帧率', _frameRate()),
          _row('码率', _bitrate()),
          if (spec.bitrate == BitrateMode.custom) _row('', _customKbps()),
          _row('编码', _codec()),
          _row('格式', _format()),
          if (durationMs > 0) _row('预计大小', _estimatedSize()),
        ],
      );

  /// 剪映式的一行：左边标签定宽，右边控件。
  ///
  /// 控件**有宽度上限**：「1080P」「30fps」这种两三个字的选择器铺满一整行
  /// （真机上是 940px）看起来廉价，眼睛还要从最左的标签一路扫到最右的
  /// 下拉箭头（2026-09-09 设计走查）。给它一个够用的宽度就停。
  static const double _controlMaxWidth = 260;

  Widget _row(String name, Widget child) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: Row(children: [
          SizedBox(
            width: 64,
            child: Text(name,
                style: const TextStyle(
                    fontSize: AppFontSize.caption,
                    color: AppColors.textSecondary)),
          ),
          Flexible(
            child: Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints:
                    const BoxConstraints(maxWidth: _controlMaxWidth),
                child: child,
              ),
            ),
          ),
        ]),
      );

  Widget _label(String text) => Text(text,
      style: const TextStyle(
          fontSize: AppFontSize.caption,
          fontWeight: FontWeight.w600,
          color: AppColors.textSecondary));

  Widget _pickMode() {
    // 组合只有一条时没得挑，别摆一个选了也没用的开关
    if (totalCombos <= 1) {
      return const Text('只有 1 条组合',
          style: TextStyle(
              fontSize: AppFontSize.caption, color: AppColors.textTertiary));
    }
    final picking = pickCount != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          _choice(
            key: const Key('export-mode-all'),
            label: '全部 $totalCombos 条',
            selected: !picking,
            onTap: () => onPickCountChanged(null),
          ),
          const SizedBox(width: AppSpacing.sm),
          _choice(
            key: const Key('export-mode-pick'),
            label: '挑差异最大的',
            selected: picking,
            // 默认挑 5 条，或者全部（组合少于 5 条时）
            onTap: () => onPickCountChanged(totalCombos < 5 ? totalCombos : 5),
          ),
        ]),
        if (picking) ...[
          const SizedBox(height: AppSpacing.sm),
          Row(children: [
            const Text('挑 ',
                style: TextStyle(
                    fontSize: AppFontSize.caption,
                    color: AppColors.textSecondary)),
            for (final n in _pickOptions) ...[
              _choice(
                key: Key('export-pick-$n'),
                label: '$n',
                selected: pickCount == n,
                onTap: () => onPickCountChanged(n),
              ),
              const SizedBox(width: AppSpacing.xs),
            ],
            const Text(' 条',
                style: TextStyle(
                    fontSize: AppFontSize.caption,
                    color: AppColors.textSecondary)),
          ]),
          const SizedBox(height: AppSpacing.xs),
          const Text(
            '按素材本身的差异挑：同一批拍摄出来的素材算「一样」，'
            '并尽量让每条素材都露一次面',
            style: TextStyle(
                fontSize: AppFontSize.micro,
                height: 1.5,
                color: AppColors.textTertiary),
          ),
        ],
      ],
    );
  }

  List<int> get _pickOptions =>
      [for (final n in const [3, 5, 10, 20]) if (n < totalCombos) n];

  Widget _resolution() => _dropdown(
        value: '${spec.shortSide}',
        items: [
          for (final r in ExportSpec.resolutions) ('${r.shortSide}', r.label),
        ],
        onChanged: (v) => onSpecChanged(spec.copyWith(shortSide: int.parse(v))),
      );

  Widget _frameRate() => _dropdown(
        value: '${spec.fps}',
        items: [for (final f in ExportSpec.frameRates) ('$f', '${f}fps')],
        onChanged: (v) => onSpecChanged(spec.copyWith(fps: int.parse(v))),
      );

  /// 选项是**具体数字**，档位名只是后缀注明。数字按当前分辨率 × 帧率算，
  /// 改了分辨率或帧率，这里的数字跟着变
  Widget _bitrate() => _dropdown(
        value: spec.bitrate.name,
        items: [
          (
            'recommended',
            '${spec.kbpsOf(BitrateMode.recommended) ~/ 1000} Mbps（推荐）'
          ),
          ('higher', '${spec.kbpsOf(BitrateMode.higher) ~/ 1000} Mbps（更高）'),
          ('lower', '${spec.kbpsOf(BitrateMode.lower) ~/ 1000} Mbps（更低）'),
          ('custom', '自定义'),
        ],
        onChanged: (v) => onSpecChanged(spec.copyWith(
            bitrate: BitrateMode.values.firstWhere((m) => m.name == v))),
      );

  Widget _codec() => _dropdown(
        value: spec.codec.name,
        items: const [('h264', 'H.264'), ('hevc', 'HEVC')],
        onChanged: (v) => onSpecChanged(spec.copyWith(
            codec: VideoCodec.values.firstWhere((c) => c.name == v))),
      );

  Widget _format() => _dropdown(
        value: spec.format.name,
        items: const [('mp4', 'mp4'), ('mov', 'mov')],
        onChanged: (v) => onSpecChanged(spec.copyWith(
            format: ContainerFormat.values.firstWhere((f) => f.name == v))),
      );

  Widget _customKbps() => TextFormField(
        key: const Key('export-custom-kbps'),
        initialValue: '${spec.customKbps}',
        enabled: enabled,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        style: const TextStyle(
            fontSize: AppFontSize.caption, color: AppColors.textPrimary),
        decoration: const InputDecoration(
          isDense: true,
          suffixText: 'kbps',
          helperText: '1080P 建议 ≥12000，4K 建议 ≥25000',
          helperStyle: TextStyle(
              fontSize: AppFontSize.micro, color: AppColors.textTertiary),
          contentPadding: EdgeInsets.symmetric(
              horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
          border: OutlineInputBorder(),
        ),
        onChanged: (raw) {
          final value = int.tryParse(raw);
          if (value == null || value <= 0) return;
          // 上限跟剪映一致。不夹的话填个天文数字会让 ffmpeg 直接失败，
          // 而错误信息里根本看不出是这儿填的
          onSpecChanged(spec.copyWith(
              customKbps: value.clamp(1, ExportSpec.maxCustomKbps)));
        },
      );

  /// 剪映靠这个数字让人感知每一档的差别：换任何一项它都跟着变。
  /// 码率是定死的，大小可以直接算（码率 × 时长，加音频约 128kbps）
  Widget _estimatedSize() {
    final mb = ((spec.kbps + 128) / 8) * (durationMs / 1000) / 1024;
    final text = mb >= 1000
        ? '每条约 ${(mb / 1024).toStringAsFixed(2)} GB'
        : '每条约 ${mb.ceil()} MB';
    return Text(text,
        key: const Key('export-estimated-size'),
        style: const TextStyle(
            fontSize: AppFontSize.caption, color: AppColors.textPrimary));
  }

  Widget _dropdown({
    required String value,
    required List<(String, String)> items,
    required ValueChanged<String> onChanged,
  }) =>
      DropdownButtonFormField<String>(
        initialValue: value,
        isDense: true,
        isExpanded: true,
        dropdownColor: AppColors.surfaceCard,
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(
              horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
          border: OutlineInputBorder(),
        ),
        style: const TextStyle(
            fontSize: AppFontSize.caption, color: AppColors.textPrimary),
        items: [
          for (final (key, label) in items)
            DropdownMenuItem(value: key, child: Text(label)),
        ],
        onChanged:
            enabled ? (value) => value == null ? null : onChanged(value) : null,
      );

  Widget _choice({
    required Key key,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) =>
      InkWell(
        key: key,
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
          decoration: BoxDecoration(
            color: selected ? AppColors.accentBlue : AppColors.surfaceCard,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(color: AppColors.border),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: AppFontSize.caption,
                  color: selected ? Colors.white : AppColors.textSecondary)),
        ),
      );
}
