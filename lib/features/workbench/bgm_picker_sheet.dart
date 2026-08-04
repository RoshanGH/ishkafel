import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/audio/bgm_library.dart';
import '../../core/audio/bgm_plan.dart';

/// 音频库检索入口（缺省走真实 miaoa CLI；测试注入假实现）
final bgmLibraryProvider = Provider<BgmLibrary>((ref) => BgmLibrary());

/// 用户在配乐选择面板里的决定
sealed class BgmChoice {
  const BgmChoice();
}

/// 用这条素材
class BgmPicked extends BgmChoice {
  final BgmMaterial material;
  const BgmPicked(this.material);
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
}) =>
    showDialog<BgmChoice>(
      context: context,
      builder: (_) => _BgmPickerDialog(
        rangeMs: rangeMs,
        rangeLabel: rangeLabel,
        canClear: canClear,
      ),
    );

class _BgmPickerDialog extends ConsumerStatefulWidget {
  final int rangeMs;
  final String rangeLabel;
  final bool canClear;

  const _BgmPickerDialog({
    required this.rangeMs,
    required this.rangeLabel,
    required this.canClear,
  });

  @override
  ConsumerState<_BgmPickerDialog> createState() => _BgmPickerDialogState();
}

class _BgmPickerDialogState extends ConsumerState<_BgmPickerDialog> {
  final _keyword = TextEditingController();
  List<BgmMaterial>? _items;
  String? _error;

  /// 每次检索领一个代次号：用户敲得快时慢到的旧结果不能覆盖新的
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _keyword.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final generation = ++_generation;
    setState(() {
      _items = null;
      _error = null;
    });
    try {
      final items =
          await ref.read(bgmLibraryProvider).search(keyword: _keyword.text);
      if (!mounted || generation != _generation) return;
      setState(() => _items = items);
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
            ],
          ),
        ),
        actions: [
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
    final items = _items;
    if (items == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (items.isEmpty) {
      return const Center(
        child: Text('音频库里没有匹配的内容',
            style: TextStyle(
                color: AppColors.textTertiary, fontSize: AppFontSize.body)),
      );
    }
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, _) =>
          const Divider(height: 1, color: AppColors.border),
      itemBuilder: (_, i) => _Row(
        material: items[i],
        rangeMs: widget.rangeMs,
        onTap: () => Navigator.of(context).pop(BgmPicked(items[i])),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final BgmMaterial material;
  final int rangeMs;
  final VoidCallback onTap;

  const _Row(
      {required this.material, required this.rangeMs, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final fit = BgmPlan.fitFor(
        materialDurationMs: material.durationMs, rangeMs: rangeMs);
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
          ],
        ),
      ),
    );
  }
}

String _seconds(int ms) => '${(ms / 1000).toStringAsFixed(1)}s';
