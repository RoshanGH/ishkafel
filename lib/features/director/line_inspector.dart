import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/audio/voice_catalog.dart';
import '../../core/script/script_doc.dart';
import '../../core/script/shot_allocation.dart';
import '../picking/picked_media_cache.dart';

/// 编导台右栏：当前行的工作台。
///
/// M2：配音节点亮——选音色、语速、显式「生成配音」、试听、过期提示。
/// 镜头（M3）、字幕（M6）的分节会依次长在这里——「参数跟对象走」。
class LineInspector extends StatelessWidget {
  final int index;
  final ScriptLine line;
  final ValueChanged<int?> onManualMsChanged;

  /// 配音能力是否可用（语音凭据齐了才有）；不可用时按钮禁用并说明原因
  final bool voiceAvailable;

  /// 这一行正在生成配音
  final bool generating;

  /// 这一行的配音正在试听
  final bool playing;

  final VoidCallback onPickVoice;
  final ValueChanged<int> onSpeechRateChanged;
  final VoidCallback onGenerate;
  final VoidCallback onTogglePlay;
  final VoidCallback onFindShots;
  final ValueChanged<int> onRemoveShot;
  final ValueChanged<String> onRemoveTag;

  /// 展开详情的镜头下标（时长/起点/速度都在详情里调）
  final int? expandedShot;
  final ValueChanged<int?> onExpandShot;
  final VoidCallback onDistribute;
  final void Function(int index, int newAllocMs) onResizeShot;
  final void Function(int index, int trimStartMs) onTrimStart;
  final void Function(int index, double speed) onShotSpeed;

  /// 素材下载状态（null = 下载器未接，不显示状态）
  final PickedMediaStatus? Function(int materialId) shotStatus;
  final ValueChanged<int> onRetryDownload;

  const LineInspector({
    super.key,
    required this.index,
    required this.line,
    required this.onManualMsChanged,
    required this.voiceAvailable,
    required this.generating,
    required this.playing,
    required this.onPickVoice,
    required this.onSpeechRateChanged,
    required this.onGenerate,
    required this.onTogglePlay,
    required this.onFindShots,
    required this.onRemoveShot,
    required this.onRemoveTag,
    this.expandedShot,
    required this.onExpandShot,
    required this.onDistribute,
    required this.onResizeShot,
    required this.onTrimStart,
    required this.onShotSpeed,
    required this.shotStatus,
    required this.onRetryDownload,
  });

  @override
  Widget build(BuildContext context) {
    final voiced = line.type == ScriptLineType.voiced;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        Row(children: [
          Text('第 ${index + 1} 行',
              style: const TextStyle(
                  fontSize: AppFontSize.emphasis,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary)),
          const SizedBox(width: AppSpacing.sm),
          _typeBadge(voiced),
        ]),
        const SizedBox(height: AppSpacing.xs),
        Text(
            voiced
                ? '配音生成后，配音时长就是这一行的时长'
                : '没有台词的行——有画面、可铺配乐',
            style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: AppFontSize.caption,
                height: 1.5)),
        const SizedBox(height: AppSpacing.lg),
        if (!voiced) ...[
          _sectionTitle('时长'),
          const SizedBox(height: AppSpacing.sm),
          _manualMsField(),
          const SizedBox(height: AppSpacing.xl),
        ],
        if (voiced) ...[
          _voiceSection(),
          const SizedBox(height: AppSpacing.xl),
        ],
        _shotsSection(),
      ],
    );
  }

  // ---- 镜头节 ----

  Widget _shotsSection() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          _sectionTitle('镜头'),
          if (line.shots.isNotEmpty) ...[
            const SizedBox(width: AppSpacing.xs),
            Text('${line.shots.length} 个',
                style: const TextStyle(
                    fontSize: AppFontSize.micro,
                    color: AppColors.textTertiary)),
          ],
          const Spacer(),
          TextButton.icon(
            key: const ValueKey('inspector-find-shots'),
            onPressed: onFindShots,
            icon: const Icon(Icons.search, size: 13),
            label: Text(line.shots.isEmpty ? '找镜头' : '增删镜头',
                style: const TextStyle(fontSize: AppFontSize.caption)),
          ),
        ]),
        if (line.tags.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xs),
          Wrap(spacing: AppSpacing.xs, runSpacing: AppSpacing.xs, children: [
            for (final tag in line.tags)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.surfaceRaised,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: AppColors.border),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(tag,
                      style: const TextStyle(
                          fontSize: AppFontSize.micro,
                          color: AppColors.textSecondary)),
                  const SizedBox(width: 3),
                  InkWell(
                    key: ValueKey('inspector-remove-tag-$tag'),
                    onTap: () => onRemoveTag(tag),
                    child: const Icon(Icons.close,
                        size: 10, color: AppColors.textTertiary),
                  ),
                ]),
              ),
          ]),
        ],
        const SizedBox(height: AppSpacing.sm),
        if (line.shots.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.surfaceRaised.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(color: AppColors.border),
            ),
            child: const Text('还没有镜头。点「找镜头」从素材库挑几段画面',
                style: TextStyle(
                    fontSize: AppFontSize.caption,
                    color: AppColors.textTertiary,
                    height: 1.4)),
          )
        else ...[
          _allocationHeader(),
          const SizedBox(height: AppSpacing.sm),
          SizedBox(
            height: 118,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: line.shots.length,
              separatorBuilder: (_, _) =>
                  const SizedBox(width: AppSpacing.sm),
              itemBuilder: (context, i) => _shotCard(i, line.shots[i]),
            ),
          ),
          if (expandedShot != null &&
              expandedShot! >= 0 &&
              expandedShot! < line.shots.length) ...[
            const SizedBox(height: AppSpacing.sm),
            _shotDetail(expandedShot!, line.shots[expandedShot!]),
          ],
        ],
      ]);

  /// 分配状态一行：行时长根、已分配、缺口警告与「均分」入口。
  /// 「每一次等待都要有交代」同理——每一个数也要有出处
  Widget _allocationHeader() {
    final root = ShotAllocation.rootMsOf(line);
    if (root == null) {
      return Text(
          line.type == ScriptLineType.voiced
              ? '先生成配音，再给镜头分时长（配音时长是这一行的根）'
              : '素材时长未知，先在上方填一个时长',
          style: const TextStyle(
              fontSize: AppFontSize.caption, color: AppColors.textTertiary));
    }
    final shortfall = ShotAllocation.shortfallMs(line.shots, root);
    return Row(children: [
      Text('行时长 ${_s(root)}',
          style: const TextStyle(
              fontSize: AppFontSize.caption,
              color: AppColors.textSecondary,
              fontFeatures: [FontFeature.tabularFigures()])),
      const SizedBox(width: AppSpacing.sm),
      if (shortfall > 0)
        Expanded(
          child: Text('还有 ${_s(shortfall)} 没分出去（素材可能不够长）',
              style: const TextStyle(
                  fontSize: AppFontSize.caption, color: AppColors.orange)),
        )
      else if (shortfall < 0)
        Expanded(
          child: Text('超分了 ${_s(-shortfall)}',
              style: const TextStyle(
                  fontSize: AppFontSize.caption, color: AppColors.orange)),
        )
      else
        const Spacer(),
      TextButton(
        key: const ValueKey('inspector-distribute'),
        onPressed: onDistribute,
        style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            textStyle: const TextStyle(fontSize: AppFontSize.caption)),
        child: const Text('均分'),
      ),
    ]);
  }

  static String _s(int ms) => '${(ms / 1000).toStringAsFixed(1)}s';

  /// 选中镜头的详情：时长（邻镜联动）、起点（框选不必从头）、速度。
  /// 帧级胶片条在后续版本升级；这里数值精确到 0.1s
  Widget _shotDetail(int i, LineShot shot) {
    final alloc = shot.allocMs;
    final src = shot.durationMs;
    final maxStart = src == null ? 0 : (src - shot.consumedSourceMs).clamp(0, src);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('第 ${i + 1} 镜',
              style: const TextStyle(
                  fontSize: AppFontSize.caption,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary)),
          const Spacer(),
          Text(src == null ? '素材时长未知' : '素材 ${_s(src)}',
              style: const TextStyle(
                  fontSize: AppFontSize.micro, color: AppColors.textTertiary)),
        ]),
        const SizedBox(height: AppSpacing.sm),
        // 时长：±0.5s 步进，邻镜联动
        Row(children: [
          const SizedBox(
              width: 34,
              child: Text('时长',
                  style: TextStyle(
                      fontSize: AppFontSize.caption,
                      color: AppColors.textSecondary))),
          IconButton(
            key: ValueKey('shot-alloc-minus-$i'),
            visualDensity: VisualDensity.compact,
            iconSize: 14,
            onPressed: alloc == null
                ? null
                : () => onResizeShot(i, alloc - 500),
            icon: const Icon(Icons.remove, color: AppColors.textSecondary),
          ),
          Text(alloc == null ? '未分配' : _s(alloc),
              style: const TextStyle(
                  fontSize: AppFontSize.body,
                  color: AppColors.textPrimary,
                  fontFeatures: [FontFeature.tabularFigures()])),
          IconButton(
            key: ValueKey('shot-alloc-plus-$i'),
            visualDensity: VisualDensity.compact,
            iconSize: 14,
            onPressed: alloc == null
                ? null
                : () => onResizeShot(i, alloc + 500),
            icon: const Icon(Icons.add, color: AppColors.textSecondary),
          ),
          const Spacer(),
          Text('相邻镜头会自动让出/补上',
              style: TextStyle(
                  fontSize: AppFontSize.micro,
                  color: AppColors.textTertiary.withValues(alpha: 0.8))),
        ]),
        // 起点：框选不必从头
        if (src != null && maxStart > 0)
          Row(children: [
            const SizedBox(
                width: 34,
                child: Text('起点',
                    style: TextStyle(
                        fontSize: AppFontSize.caption,
                        color: AppColors.textSecondary))),
            Expanded(
              child: SliderTheme(
                data: const SliderThemeData(
                    trackHeight: 2,
                    thumbShape:
                        RoundSliderThumbShape(enabledThumbRadius: 5)),
                child: Slider(
                  key: ValueKey('shot-trim-$i'),
                  value: shot.trimStartMs
                      .clamp(0, maxStart)
                      .toDouble(),
                  max: maxStart.toDouble(),
                  activeColor: AppColors.accentBlue,
                  onChanged: (v) => onTrimStart(i, v.round()),
                ),
              ),
            ),
            SizedBox(
                width: 40,
                child: Text(_s(shot.trimStartMs),
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                        fontSize: AppFontSize.micro,
                        color: AppColors.textSecondary,
                        fontFeatures: [FontFeature.tabularFigures()]))),
          ]),
        const SizedBox(height: AppSpacing.xs),
        // 速度：显式变速，变速清框重选
        Row(children: [
          const SizedBox(
              width: 34,
              child: Text('速度',
                  style: TextStyle(
                      fontSize: AppFontSize.caption,
                      color: AppColors.textSecondary))),
          for (final v in const [0.75, 1.0, 1.25, 1.5])
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.xs),
              child: InkWell(
                key: ValueKey('shot-speed-$i-$v'),
                onTap: () => onShotSpeed(i, v),
                borderRadius: BorderRadius.circular(999),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: shot.speed == v
                        ? AppColors.accentBlue.withValues(alpha: 0.16)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                        color: shot.speed == v
                            ? AppColors.accentBlue
                            : AppColors.border),
                  ),
                  child: Text('${v}x',
                      style: TextStyle(
                          fontSize: AppFontSize.micro,
                          fontWeight: shot.speed == v
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: shot.speed == v
                              ? AppColors.accentBlueLight
                              : AppColors.textSecondary)),
                ),
              ),
            ),
          const Spacer(),
          Text('变速后重新框选',
              style: TextStyle(
                  fontSize: AppFontSize.micro,
                  color: AppColors.textTertiary.withValues(alpha: 0.8))),
        ]),
      ]),
    );
  }

  Widget _shotCard(int i, LineShot shot) {
    final expanded = expandedShot == i;
    final status = shotStatus(shot.materialId);
    return InkWell(
      key: ValueKey('inspector-shot-$i'),
      onTap: () => onExpandShot(expanded ? null : i),
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Container(
        width: 64,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(
              color: expanded ? AppColors.accentBlue : AppColors.border,
              width: expanded ? 1.5 : 1),
          color: AppColors.surfaceRaised,
        ),
        clipBehavior: Clip.antiAlias,
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: Stack(fit: StackFit.expand, children: [
              shot.thumbnailUrl == null
                  ? Container(color: Colors.black)
                  : Image.network(shot.thumbnailUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          Container(color: Colors.black)),
              Positioned(
                left: 3,
                top: 3,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(3)),
                  child: Text('${i + 1}',
                      style: const TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                ),
              ),
              Positioned(
                right: 1,
                top: 1,
                child: InkWell(
                  key: ValueKey('inspector-remove-shot-$i'),
                  onTap: () => onRemoveShot(i),
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(3)),
                    child: const Icon(Icons.close,
                        size: 10, color: Colors.white),
                  ),
                ),
              ),
              // 下载状态：素材固定到本地才有得播；失败点角标重试
              if (status == PickedMediaStatus.downloading)
                const Positioned(
                  left: 3,
                  bottom: 3,
                  child: SizedBox(
                      width: 9,
                      height: 9,
                      child: CircularProgressIndicator(
                          strokeWidth: 1.2, color: Colors.white)),
                )
              else if (status == PickedMediaStatus.failed)
                Positioned(
                  left: 1,
                  bottom: 1,
                  child: InkWell(
                    key: ValueKey('inspector-shot-retry-$i'),
                    onTap: () => onRetryDownload(shot.materialId),
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                          color: AppColors.red.withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(3)),
                      child: const Icon(Icons.refresh,
                          size: 10, color: Colors.white),
                    ),
                  ),
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.all(3),
            child: Text(
                shot.allocMs != null
                    ? '${(shot.allocMs! / 1000).toStringAsFixed(1)}s'
                    : (shot.durationMs == null
                        ? '时长未知'
                        : '${(shot.durationMs! / 1000).toStringAsFixed(1)}s'),
                style: TextStyle(
                    fontSize: 9,
                    color: shot.allocMs != null
                        ? AppColors.textSecondary
                        : AppColors.textTertiary,
                    fontFeatures: const [FontFeature.tabularFigures()])),
          ),
        ]),
      ),
    );
  }

  // ---- 配音节 ----

  Widget _voiceSection() {
    final vo = line.voiceover;
    final state = line.voiceState;
    final voiceName = line.voiceId == null
        ? null
        : (VoiceCatalog.byId(line.voiceId!)?.ref.name ?? line.voiceId);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        _sectionTitle('配音'),
        const Spacer(),
        if (state == LineVoiceState.fresh)
          const _StatusChip(text: '已生成', color: AppColors.green)
        else if (state == LineVoiceState.stale)
          const _StatusChip(text: '已过期', color: AppColors.orange),
      ]),
      const SizedBox(height: AppSpacing.sm),
      // 音色
      InkWell(
        key: const ValueKey('inspector-pick-voice'),
        onTap: onPickVoice,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: AppSpacing.sm),
          decoration: BoxDecoration(
            color: AppColors.surfaceRaised,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(children: [
            const Icon(Icons.record_voice_over_outlined,
                size: 15, color: AppColors.textSecondary),
            const SizedBox(width: AppSpacing.sm),
            Text(voiceName ?? '选择音色',
                style: TextStyle(
                    fontSize: AppFontSize.body,
                    color: voiceName == null
                        ? AppColors.textTertiary
                        : AppColors.textPrimary)),
            const Spacer(),
            const Icon(Icons.unfold_more,
                size: 14, color: AppColors.textTertiary),
          ]),
        ),
      ),
      const SizedBox(height: AppSpacing.md),
      // 语速
      Row(children: [
        const Text('语速',
            style: TextStyle(
                fontSize: AppFontSize.caption,
                color: AppColors.textSecondary)),
        const SizedBox(width: AppSpacing.sm),
        Expanded(child: _rateSelector()),
      ]),
      const SizedBox(height: AppSpacing.md),
      // 生成按钮：显式触发——改了字只标黄，点这里才花钱
      Tooltip(
        message: voiceAvailable ? '' : '尚未配置 AI 服务（语音合成），无法生成配音',
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            key: const ValueKey('inspector-generate-voice'),
            onPressed: voiceAvailable && !generating ? onGenerate : null,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accentBlue,
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              textStyle: const TextStyle(
                  fontSize: AppFontSize.body, fontWeight: FontWeight.w600),
            ),
            icon: generating
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.5, color: Colors.white))
                : const Icon(Icons.graphic_eq, size: 14),
            label: Text(generating
                ? '正在生成…'
                : (vo == null ? '生成配音' : '重新生成')),
          ),
        ),
      ),
      // 试听条：旧配音也能听（过期只是提醒，不是没收）
      if (vo != null) ...[
        const SizedBox(height: AppSpacing.md),
        Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
          decoration: BoxDecoration(
            color: AppColors.surfaceRaised,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(children: [
            IconButton(
              key: const ValueKey('inspector-play-voice'),
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              onPressed: onTogglePlay,
              icon: Icon(playing ? Icons.stop : Icons.play_arrow,
                  color: AppColors.textPrimary),
              tooltip: playing ? '停止' : '试听',
            ),
            Text('${(vo.durationMs / 1000).toStringAsFixed(1)} 秒',
                style: const TextStyle(
                    fontSize: AppFontSize.body,
                    color: AppColors.textPrimary,
                    fontFeatures: [FontFeature.tabularFigures()])),
            const Spacer(),
            if (state == LineVoiceState.stale)
              const Padding(
                padding: EdgeInsets.only(right: AppSpacing.xs),
                child: Text('内容已改，这是旧配音',
                    style: TextStyle(
                        fontSize: AppFontSize.micro,
                        color: AppColors.orange)),
              ),
          ]),
        ),
      ],
    ]);
  }

  static const _rates = [(-25, '0.75x'), (0, '1x'), (25, '1.25x'), (50, '1.5x')];

  Widget _rateSelector() => Row(children: [
        for (final (value, label) in _rates)
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.xs),
            child: _RatePill(
              label: label,
              selected: line.speechRate == value,
              onTap: () => onSpeechRateChanged(value),
            ),
          ),
      ]);

  // ---- 通用 ----

  Widget _typeBadge(bool voiced) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: (voiced ? AppColors.accentBlue : AppColors.textTertiary)
              .withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(voiced ? '配音行' : '画面行',
            style: TextStyle(
                fontSize: AppFontSize.micro,
                fontWeight: FontWeight.w600,
                color: voiced
                    ? AppColors.accentBlueLight
                    : AppColors.textSecondary)),
      );

  Widget _sectionTitle(String text) => Text(text,
      style: const TextStyle(
          fontSize: AppFontSize.caption,
          fontWeight: FontWeight.w600,
          color: AppColors.textSecondary));

  /// 画面行的手填时长：手填即根；不填则跟随所选素材（设计稿问题③）
  Widget _manualMsField() {
    final seconds =
        line.manualMs == null ? '' : (line.manualMs! / 1000).toStringAsFixed(1);
    return Row(children: [
      SizedBox(
        width: 96,
        child: TextFormField(
          key: ValueKey('manual-ms-${line.id}'),
          initialValue: seconds,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(
              fontSize: AppFontSize.body, color: AppColors.textPrimary),
          decoration: InputDecoration(
            isDense: true,
            suffixText: '秒',
            suffixStyle: const TextStyle(
                fontSize: AppFontSize.caption, color: AppColors.textTertiary),
            hintText: '随素材',
            hintStyle: const TextStyle(
                fontSize: AppFontSize.body, color: AppColors.textTertiary),
            filled: true,
            fillColor: AppColors.surfaceRaised,
            contentPadding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm, vertical: AppSpacing.sm),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              borderSide: const BorderSide(color: AppColors.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              borderSide: const BorderSide(color: AppColors.border),
            ),
          ),
          onChanged: (v) {
            final parsed = double.tryParse(v.trim());
            onManualMsChanged(parsed == null || parsed <= 0
                ? null
                : (parsed * 1000).round());
          },
        ),
      ),
      const SizedBox(width: AppSpacing.md),
      const Expanded(
        child: Text('不填则跟随所选素材的时长',
            style: TextStyle(
                color: AppColors.textTertiary,
                fontSize: AppFontSize.caption,
                height: 1.4)),
      ),
    ]);
  }
}

class _StatusChip extends StatelessWidget {
  final String text;
  final Color color;

  const _StatusChip({required this.text, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: AppFontSize.micro,
                fontWeight: FontWeight.w600,
                color: color)),
      );
}

class _RatePill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _RatePill(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        key: ValueKey('rate-$label'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
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
                  fontSize: AppFontSize.micro,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected
                      ? AppColors.accentBlueLight
                      : AppColors.textSecondary)),
        ),
      );
}
