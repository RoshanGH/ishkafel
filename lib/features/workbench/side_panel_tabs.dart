import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';

/// 右栏能显示什么。
///
/// 从「先确认切分、再进入替换选材」两个页面合并而来：切分和选材本来就是
/// 交替进行的——挑着素材发现这刀切得不对，就该直接在时间线上拖一下，而不是
/// 退出去改完再进来。所以它们不是两个阶段，是同一个工作台的两个视图。
enum SidePanelTab {
  /// 选中对象的属性：边界微调、台词、标签、AI 过程量
  inspector('属性'),

  /// 给选中对象挑替换素材
  candidates('替换素材');

  final String label;
  const SidePanelTab(this.label);
}

/// 右栏顶部的视图切换条
class SidePanelTabBar extends StatelessWidget {
  final SidePanelTab current;
  final ValueChanged<SidePanelTab> onChanged;

  /// 每个 tab 上的角标（如已选素材数）；为 null 不显示
  final Map<SidePanelTab, String?> badges;

  const SidePanelTabBar({
    super.key,
    required this.current,
    required this.onChanged,
    this.badges = const {},
  });

  @override
  Widget build(BuildContext context) => Container(
        height: 34,
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.border)),
        ),
        child: Row(
          children: [
            for (final tab in SidePanelTab.values)
              Expanded(
                child: _Tab(
                  tab: tab,
                  selected: tab == current,
                  badge: badges[tab],
                  onTap: () => onChanged(tab),
                ),
              ),
          ],
        ),
      );
}

class _Tab extends StatelessWidget {
  final SidePanelTab tab;
  final bool selected;
  final String? badge;
  final VoidCallback onTap;

  const _Tab({
    required this.tab,
    required this.selected,
    required this.badge,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkWell(
        key: Key('side-tab-${tab.name}'),
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? AppColors.accentBlue : Colors.transparent,
                width: AppStroke.emphasis,
              ),
            ),
          ),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tab.label,
                  style: TextStyle(
                    fontSize: AppFontSize.body,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected
                        ? AppColors.textPrimary
                        : AppColors.textSecondary,
                  ),
                ),
                if (badge != null) ...[
                  const SizedBox(width: AppSpacing.xs),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.xs, vertical: 1),
                    decoration: BoxDecoration(
                      color: AppColors.accentBlue.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(badge!,
                        style: const TextStyle(
                            fontSize: AppFontSize.micro,
                            color: AppColors.accentBlueLight)),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
}
