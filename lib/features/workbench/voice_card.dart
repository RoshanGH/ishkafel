import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/audio/voice_plan.dart';
import 'inspector_widgets.dart';

/// 检查器里的「配音」卡：这个台词语义单元用谁的声音。
///
/// 挂在单元层而不是镜头层：台词跟着单元走，换镜头不影响这句话是谁说的。
class VoiceCard extends StatelessWidget {
  /// 换成了哪个音色；null 表示保持原声
  final VoiceRef? voice;

  /// 为 null 表示只读（已导出的任务不该还能改配音）
  final VoidCallback? onTap;

  /// 试听已生成的配音。为 null 表示这一句还没生成过——
  /// 给一个点了没声音的按钮比不给还糟。
  final VoidCallback? onPreview;

  const VoiceCard(
      {super.key, required this.voice, this.onTap, this.onPreview});

  @override
  Widget build(BuildContext context) => inspectorCard([
        Row(
          children: [
            inspectorLabel('配音'),
            const Spacer(),
            if (onPreview != null)
              IconButton(
                key: const Key('inspector-preview-voice'),
                onPressed: onPreview,
                icon: const Icon(Icons.play_circle_outline, size: 16),
                color: AppColors.green,
                tooltip: '试听这一句的配音',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                visualDensity: VisualDensity.compact,
              ),
            if (onTap != null)
              TextButton(
                key: const Key('inspector-change-voice'),
                onPressed: onTap,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(voice == null ? '换音色' : '改',
                    style: const TextStyle(fontSize: AppFontSize.caption)),
              ),
          ],
        ),
        // 「保持原片配音」要写出来，不能留空——留空的话用户分不清是
        // 「没换」还是「这个功能没生效」
        Text(
          voice == null
              ? '保持原片配音'
              // 生成没生成是两回事：只选了音色还没跑，导出时不会有新声音
              : (onPreview == null ? '${voice!.name}（待生成）' : voice!.name),
          style: TextStyle(
            color: voice == null ? AppColors.textTertiary : AppColors.green,
            fontSize: AppFontSize.body,
          ),
        ),
      ]);
}
