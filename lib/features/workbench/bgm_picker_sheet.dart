import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/audio/bgm_library.dart';
import '../../core/audio/bgm_plan.dart';
import 'bgm_audition.dart';

/// 音频库检索入口（缺省走真实 miaoa CLI；测试注入假实现）
final bgmLibraryProvider = Provider<BgmLibrary>((ref) => BgmLibrary());

/// 用户在配乐选择面板里的决定
sealed class BgmChoice {
  const BgmChoice();
}

/// 用这条素材，音量压到 [volume]
class BgmPicked extends BgmChoice {
  final BgmMaterial material;
  final double volume;
  const BgmPicked(this.material, {this.volume = BgmSegment.defaultVolume});
}

/// 曲子不换，只改音量
class BgmVolumeChanged extends BgmChoice {
  final double volume;
  const BgmVolumeChanged(this.volume);
}

/// 这一段不要配乐了
class BgmCleared extends BgmChoice {
  const BgmCleared();
}

/// 给一段镜头挑配乐。
///
/// [rangeMs] 是这段镜头的总时长——列表里每条都要当场算出「会裁掉多少/ 要
/// 循环几遍」，用户才不必自己拿计算器比对时长。
Future<BgmChoice?> showBgmPicker(
  BuildContext context, {
  required int rangeMs,
  required String rangeLabel,
  bool canClear = false,
  List<int> projectIds = const [],
  double initialVolume = BgmSegment.defaultVolume,
}) =>
    showDialog<BgmChoice>(
      context: context,
      builder: (_) => _BgmPickerDialog(
        rangeMs: rangeMs,
        rangeLabel: rangeLabel,
        canClear: canClear,
        projectIds: projectIds,
        initialVolume: initialVolume,
      ),
    );

class _BgmPickerDialog extends ConsumerStatefulWidget {
  final int rangeMs;
  final String rangeLabel;

  /// 检索限定在哪些项目内；空表示不限项目
  final List<int> projectIds;
  final bool canClear;

  /// 这一段当前的音量。改这一段时带进来，用户看到的是现在的值而不是默认值
  final double initialVolume;

  const _BgmPickerDialog({
    required this.rangeMs,
    required this.rangeLabel,
    required this.initialVolume,
    required this.canClear,
    this.projectIds = const [],
  });

  @override
  ConsumerState<_BgmPickerDialog> createState() => _BgmPickerDialogState();
}

class _BgmPickerDialogState extends ConsumerState<_BgmPickerDialog> {
  final _keyword = TextEditingController();
  BgmSearchPage? _page;
  String? _error;
  // 在 initState 里就建好：`late final` 会拖到第一次用才初始化，而搜索出错
  // 或库里为空时压根不会走到列表，等 dispose 再去 ref.read 已经太晚了
  late final BgmAudition _audition;
  late double _volume = widget.initialVolume;

  /// 每次检索领一个代次号：用户敲得快时慢到的旧结果不能覆盖新的
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _audition = BgmAudition(createPlayer: ref.read(auditionPlayerFactoryProvider));
    _search();
  }

  @override
  void dispose() {
    // 先收播放器再拆自己：反过来的话浮层已经关了，那条歌还在响
    unawaited(_audition.shutdown());
    _audition.dispose();
    _keyword.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final generation = ++_generation;
    setState(() {
      _page = null;
      _error = null;
    });
    try {
      final page =
          await ref.read(bgmLibraryProvider)
              .search(keyword: _keyword.text, projectIds: widget.projectIds);
      if (!mounted || generation != _generation) return;
      setState(() => _page = page);
    } catch (e) {
      if (!mounted || generation != _generation) return;
      // e 已是人话（BgmLibrary 走 miaoaFriendlyError 翻译过）
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: AppColors.surfaceRaised,
        title: Text('为 ${widget.rangeLabel} 选配乐'),
        content: SizedBox(
          width: 560,
          height: 460,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('这一段共 ${_seconds(widget.rangeMs)}',
                  style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: AppFontSize.caption)),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                key: const Key('bgm-search'),
                controller: _keyword,
                onSubmitted: (_) => _search(),
                style: const TextStyle(
                    color: AppColors.textPrimary, fontSize: AppFontSize.body),
                decoration: const InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: AppColors.surface,
                  border: OutlineInputBorder(),
                  hintText: '搜音频库（留空列出全部），回车检索',
                  hintStyle: TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: AppFontSize.caption),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Expanded(child: _body()),
              _VolumeRow(
                value: _volume,
                onChanged: (v) => setState(() => _volume = v),
              ),
            ],
          ),
        ),
        actions: [
          // 曲子不换、只把音量改了的情形要有出口，否则用户被迫重选一遍
          if (widget.canClear && _volume != widget.initialVolume)
            TextButton(
              key: const Key('bgm-apply-volume'),
              onPressed: () =>
                  Navigator.of(context).pop(BgmVolumeChanged(_volume)),
              child: const Text('应用音量'),
            ),
          if (widget.canClear)
            TextButton(
              key: const Key('bgm-clear'),
              onPressed: () =>
                  Navigator.of(context).pop(const BgmCleared()),
              child: const Text('移除这段配乐'),
            ),
          TextButton(
            key: const Key('bgm-cancel'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
        ],
      );

  Widget _body() {
    if (_error case final e?) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(e,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppColors.red, fontSize: AppFontSize.body)),
            const SizedBox(height: AppSpacing.sm),
            TextButton(
                key: const Key('bgm-retry'),
                onPressed: _search,
                child: const Text('重试')),
          ],
        ),
      );
    }
    final page = _page;
    if (page == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final items = page.items;
    if (items.isEmpty) {
      return const Center(
        child: Text('音频库里没有匹配的内容',
            style: TextStyle(
                color: AppColors.textTertiary, fontSize: AppFontSize.body)),
      );
    }
    final list = ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, _) =>
          const Divider(height: 1, color: AppColors.border),
      itemBuilder: (_, i) => _Row(
        material: items[i],
        rangeMs: widget.rangeMs,
        audition: _audition,
        onTap: () =>
            Navigator.of(context).pop(BgmPicked(items[i], volume: _volume)),
      ),
    );
    if (!page.widenedFromProject) return list;
    // 不说明的话，用户会把这些曲子当成本项目的
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          key: Key('bgm-widened'),
          padding: EdgeInsets.only(bottom: AppSpacing.xs),
          child: Text('本项目下没有音频素材，已展开到全部音频库',
              style: TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: AppFontSize.caption)),
        ),
        Expanded(child: list),
      ],
    );
  }
}

/// 配乐音量：**每段独立**。用户在不同段铺不同曲子，有的本来就响、有的很闷，
/// 一个全局值必然有一段不合适。
class _VolumeRow extends StatelessWidget {
  final double value;
  final ValueChanged<double> onChanged;

  const _VolumeRow({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: AppSpacing.sm),
        child: Row(
          children: [
            const Icon(Icons.volume_up_outlined,
                size: 14, color: AppColors.textSecondary),
            const SizedBox(width: AppSpacing.xs),
            const Text('配乐音量',
                style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: AppFontSize.caption)),
            Expanded(
              child: Slider(
                key: const Key('bgm-volume'),
                value: value,
                // 上限就是原始音量：垫乐压过口播是最常见的翻车方式，
                // 给到 200% 只会让人更容易做错
                max: 1,
                divisions: 20,
                activeColor: AppColors.accentBlue,
                onChanged: onChanged,
              ),
            ),
            SizedBox(
              width: 40,
              child: Text('${(value * 100).round()}%',
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: AppFontSize.caption)),
            ),
          ],
        ),
      );
}

class _Row extends StatelessWidget {
  final BgmMaterial material;
  final int rangeMs;
  final BgmAudition audition;
  final VoidCallback onTap;

  const _Row(
      {required this.material,
      required this.rangeMs,
      required this.audition,
      required this.onTap});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: audition,
        builder: (context, _) => _row(context),
      );

  Widget _row(BuildContext context) {
    final fit = BgmPlan.fitFor(
        materialDurationMs: material.durationMs, rangeMs: rangeMs);
    final playing = audition.playingId == material.id;
    return InkWell(
      key: Key('bgm-item-${material.id}'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm, vertical: AppSpacing.sm),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(material.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: AppFontSize.body)),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                          material.durationMs == 0
                              ? '时长未知'
                              : _seconds(material.durationMs),
                          style: const TextStyle(
                              color: AppColors.textTertiary,
                              fontSize: AppFontSize.caption)),
                      const SizedBox(width: AppSpacing.sm),
                      Text(fit.label,
                          style: TextStyle(
                              color: fit == BgmFit.exact
                                  ? AppColors.green
                                  : AppColors.textSecondary,
                              fontSize: AppFontSize.caption)),
                      // 带解说的音频压在成片下面会和原片口播直接打架，
                      // 必须在选之前就说清楚，不能让用户听一遍才发现
                      if (material.hasSpeech) ...[
                        const SizedBox(width: AppSpacing.sm),
                        Container(
                          key: Key('bgm-speech-${material.id}'),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: AppColors.orange.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text('含人声',
                              style: TextStyle(
                                  color: AppColors.orange,
                                  fontSize: AppFontSize.micro)),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            // 光看名字和时长挑不出配乐：轻快到什么程度、压在口播下面吵不吵，
            // 只能听
            IconButton(
              key: Key('bgm-play-${material.id}'),
              tooltip: playing ? '停止试听' : '试听',
              onPressed: () => audition.toggle(material),
              icon: Icon(
                  playing ? Icons.stop_circle_outlined : Icons.play_circle_outline,
                  size: 22),
              color: playing ? AppColors.accentBlue : AppColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

String _seconds(int ms) => '${(ms / 1000).toStringAsFixed(1)}s';
