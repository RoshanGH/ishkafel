import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import 'task_filter.dart';

/// 任务列表的搜索与筛选条。
///
/// 只在**有任务**时出现——空列表上摆一个搜不到任何东西的搜索框，
/// 只会让人以为是自己搜错了。
class TaskListToolbar extends StatelessWidget {
  final String query;
  final TaskFilter filter;

  /// 各筛选项当前的命中数（不含关键词），用于在标签上带出数量
  final Map<TaskFilter, int> counts;

  final ValueChanged<String> onQueryChanged;
  final ValueChanged<TaskFilter> onFilterChanged;

  const TaskListToolbar({
    super.key,
    required this.query,
    required this.filter,
    required this.counts,
    required this.onQueryChanged,
    required this.onFilterChanged,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
        child: Row(
          children: [
            SizedBox(
              width: 260,
              child: _SearchField(query: query, onChanged: onQueryChanged),
            ),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final value in TaskFilter.values)
                      Padding(
                        padding: const EdgeInsets.only(right: AppSpacing.sm),
                        child: _FilterChip(
                          value: value,
                          count: counts[value] ?? 0,
                          selected: value == filter,
                          onTap: () => onFilterChanged(value),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
}

class _SearchField extends StatefulWidget {
  final String query;
  final ValueChanged<String> onChanged;

  const _SearchField({required this.query, required this.onChanged});

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.query);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        key: const Key('task-list-search'),
        controller: _controller,
        onChanged: widget.onChanged,
        style: const TextStyle(
            fontSize: AppFontSize.body, color: AppColors.textPrimary),
        decoration: InputDecoration(
          isDense: true,
          hintText: '搜索任务名 / ID',
          hintStyle: const TextStyle(
              fontSize: AppFontSize.body, color: AppColors.textTertiary),
          prefixIcon: const Icon(Icons.search,
              size: 15, color: AppColors.textTertiary),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 30, minHeight: 30),
          suffixIcon: _controller.text.isEmpty
              ? null
              : IconButton(
                  key: const Key('task-list-search-clear'),
                  icon: const Icon(Icons.close,
                      size: 14, color: AppColors.textTertiary),
                  onPressed: () {
                    _controller.clear();
                    widget.onChanged('');
                    setState(() {});
                  },
                ),
          filled: true,
          fillColor: AppColors.surface,
          contentPadding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: AppSpacing.sm),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
            borderSide: const BorderSide(color: AppColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
            borderSide: const BorderSide(color: AppColors.border),
          ),
        ),
      );
}

class _FilterChip extends StatelessWidget {
  final TaskFilter value;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  const _FilterChip({
    required this.value,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Material(
        color: selected
            ? AppColors.accentBlue.withValues(alpha: 0.16)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md, vertical: AppSpacing.sm),
            child: Text(
              // 数量写在标签上，用户不点进去也知道有没有东西
              count > 0 ? '${value.label} $count' : value.label,
              style: TextStyle(
                fontSize: AppFontSize.body,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected
                    ? AppColors.accentBlueLight
                    : AppColors.textSecondary,
              ),
            ),
          ),
        ),
      );
}

/// 搜索/筛选之后一条都不剩时的说明。
///
/// 直接给一片空白，用户分不清是「真没有」还是「界面坏了」；
/// 而且必须给一个一键回到全部的出口。
class NoMatchView extends StatelessWidget {
  final String query;
  final TaskFilter filter;
  final VoidCallback onReset;

  const NoMatchView({
    super.key,
    required this.query,
    required this.filter,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off,
                size: AppSpacing.xxl, color: AppColors.textTertiary),
            const SizedBox(height: AppSpacing.md),
            Text(_message(),
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: AppFontSize.body,
                    height: 1.6,
                    color: AppColors.textSecondary)),
            const SizedBox(height: AppSpacing.md),
            OutlinedButton(
                key: const Key('task-list-reset-filter'),
                onPressed: onReset,
                child: const Text('清除筛选')),
          ],
        ),
      );

  String _message() {
    final keyword = query.trim();
    if (keyword.isNotEmpty && filter != TaskFilter.all) {
      return '「${filter.label}」里没有匹配「$keyword」的任务。';
    }
    if (keyword.isNotEmpty) return '没有匹配「$keyword」的任务。';
    return '当前没有「${filter.label}」的任务。';
  }
}
