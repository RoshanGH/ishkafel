import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/export/export_spec.dart';

/// 导出前要定的两件事：**出多少条**、**出多大多清楚**。
///
/// 单独一个组件，因为导出确认页本来就长（进度、历史、失败原因都在那儿），
/// 再塞两组选项进去就没法看了。
class ExportOptionsPanel extends StatelessWidget {
  final ExportSpec spec;
  final ValueChanged<ExportSpec> onSpecChanged;

  /// 全部排列组合有多少条
  final int totalCombos;

  /// null = 全部导出；否则是「只挑这么多条差异最大的」
  final int? pickCount;
  final ValueChanged<int?> onPickCountChanged;

  final bool enabled;

  const ExportOptionsPanel({
    super.key,
    required this.spec,
    required this.onSpecChanged,
    required this.totalCombos,
    required this.pickCount,
    required this.onPickCountChanged,
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
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: _field('分辨率', _resolution())),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: _field('帧率', _frameRate())),
          ]),
          const SizedBox(height: AppSpacing.sm),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: _field('码率', _bitrate())),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: _field('编码', _codec())),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: _field('格式', _format())),
          ]),
          if (spec.bitrate == BitrateMode.custom) ...[
            const SizedBox(height: AppSpacing.sm),
            _customKbps(),
          ],
          const SizedBox(height: AppSpacing.xs),
          Text(_specNote,
              style: const TextStyle(
                  fontSize: AppFontSize.micro,
                  height: 1.5,
                  color: AppColors.textTertiary)),
        ],
      );

  /// 每个下拉头上的字段名。光秃秃一个「推荐」，没人知道是什么的推荐
  Widget _field(String name, Widget child) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name,
              style: const TextStyle(
                  fontSize: AppFontSize.micro, color: AppColors.textTertiary)),
          const SizedBox(height: 2),
          child,
        ],
      );

  /// 只在**真的会咬人**的时候出声，不是每种组合都念一句
  String get _specNote {
    final notes = <String>[];
    if (spec.shortSide > 1080) {
      notes.add('素材本身是 1080 竖版，往上放大不会更清楚，只会让文件变大');
    }
    if (spec.codec == VideoCodec.hevc) {
      notes.add('HEVC 文件小三成，但编码慢得多，且部分平台与老设备不认');
    }
    if (spec.format == ContainerFormat.mov) {
      notes.add('mov 主要给剪辑软件用；投放平台一般吃 mp4');
    }
    if (notes.isNotEmpty) return notes.join('；');
    // 码率档位的效果要说人话：文件多大、画质如何，不是一个词摆在那儿
    return switch (spec.bitrate) {
      BitrateMode.lower => '码率更低：同样内容压得更狠，文件小三四成，画质略降——快速过稿用',
      BitrateMode.recommended =>
        '导出 ${spec.width}×${spec.height} · ${spec.fps}fps · 码率按分辨率与帧率自动匹配',
      BitrateMode.higher => '码率更高：细节保留更多，文件明显更大——对画质苛刻时用',
      BitrateMode.custom => '按填入的数值定死码率，不随画面复杂度浮动',
    };
  }

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
          for (final r in ExportSpec.resolutions)
            ('${r.shortSide}', '${r.label}（${r.shortSide}×${_tall(r.shortSide)}）'),
        ],
        onChanged: (v) =>
            onSpecChanged(spec.copyWith(shortSide: int.parse(v))),
      );

  static int _tall(int shortSide) {
    final raw = (shortSide * 16 / 9).round();
    return raw.isEven ? raw : raw + 1;
  }

  Widget _frameRate() => _dropdown(
        value: '${spec.fps}',
        items: [for (final f in ExportSpec.frameRates) ('$f', '$f fps')],
        onChanged: (v) => onSpecChanged(spec.copyWith(fps: int.parse(v))),
      );

  Widget _bitrate() => _dropdown(
        value: spec.bitrate.name,
        items: const [
          ('lower', '更低'),
          ('recommended', '推荐'),
          ('higher', '更高'),
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

  Widget _customKbps() => Row(children: [
        const Text('码率 ',
            style: TextStyle(
                fontSize: AppFontSize.caption,
                color: AppColors.textSecondary)),
        SizedBox(
          width: 110,
          child: TextFormField(
            key: const Key('export-custom-kbps'),
            initialValue: '${spec.customKbps}',
            enabled: enabled,
            keyboardType: TextInputType.number,
            style: const TextStyle(
                fontSize: AppFontSize.caption, color: AppColors.textPrimary),
            decoration: const InputDecoration(
              isDense: true,
              suffixText: 'kbps',
              contentPadding: EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
              border: OutlineInputBorder(),
            ),
            onChanged: (raw) {
              final value = int.tryParse(raw);
              if (value == null || value <= 0) return;
              // 上限跟剪映一致。不夹的话填个 999999999 会让 ffmpeg
              // 直接失败，而错误信息里根本看不出是这儿填的
              onSpecChanged(spec.copyWith(
                  customKbps: value.clamp(1, ExportSpec.maxCustomKbps)));
            },
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        const Expanded(
          child: Text('1080P 建议 ≥12000，4K 建议 ≥25000',
              style: TextStyle(
                  fontSize: AppFontSize.micro, color: AppColors.textTertiary)),
        ),
      ]);

  Widget _dropdown({
    required String value,
    required List<(String, String)> items,
    required ValueChanged<String> onChanged,
  }) =>
      DropdownButtonFormField<String>(
        initialValue: value,
        isDense: true,
        // 窄列里长文案（如「1080P（1080×1920）」）会把 Row 挤爆
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
