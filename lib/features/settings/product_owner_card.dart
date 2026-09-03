import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import 'settings_widgets.dart';

/// 产品负责人：**告诉人「有问题找谁」**。
///
/// 不是功能，是一条去处。软件出了别扭的地方、想要的功能没有——人第一反应
/// 是「跟谁说」，说不出去的抱怨就烂在心里，问题也就永远不会被修。
/// 把人和去处摆在这里，反馈才有一条真实的路。
///
/// 放在「关于」里：来这一页的人多半正是因为出了问题要查版本、要找人，
/// 而版本号那张卡已经写着「反馈问题时附上版本号」——正好接上。
class ProductOwnerCard extends StatelessWidget {
  const ProductOwnerCard({super.key});

  static const _name = '方泽文';
  static const _role = '产品负责人';
  static const _avatar = 'assets/images/owner_fangzewen.jpg';

  @override
  Widget build(BuildContext context) => SettingsCard(
        title: '有问题找谁',
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md,
                AppSpacing.md, AppSpacing.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // 头像：圆形 + 一圈极淡的描边，贴 macOS 的通讯录/联系人观感
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: AppColors.textPrimary.withValues(alpha: 0.12)),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Image.asset(_avatar, fit: BoxFit.cover),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(children: [
                        const Text(_name,
                            style: TextStyle(
                                fontSize: AppFontSize.emphasis,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary)),
                        const SizedBox(width: AppSpacing.sm),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color:
                                AppColors.accentBlue.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(AppRadius.sm),
                          ),
                          child: const Text(_role,
                              style: TextStyle(
                                  fontSize: AppFontSize.micro,
                                  color: AppColors.accentBlueLight)),
                        ),
                      ]),
                      const SizedBox(height: 4),
                      const Text('在飞书上找他',
                          style: TextStyle(
                              fontSize: AppFontSize.caption,
                              color: AppColors.textSecondary)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.border),
          const SettingsNote('用着别扭的地方、做不了的事、想要的功能，都在飞书上'
              '找他反馈。他会统一收集，评估之后排进后续版本的开发计划。\n\n'
              '说清楚三件事能省掉大半来回：你当时在做什么、你期望是什么样、'
              '实际是什么样。带上上面的版本号，必要时把界面截个图。'),
        ],
      );
}
