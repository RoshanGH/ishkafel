import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';

/// 一步一步报进度的模态框。
///
/// 落地一百多个素材、跑几十次 ffmpeg 这类活儿，界面上不能干卡着——
/// 「超过一两秒的操作要有进度或预期」。两个工作页（工作台、编导台）
/// 都在用，抽出来是为了不写两遍、也不会一边改了另一边忘了。
class LongTaskProgress {
  final String step;

  /// 0~1；null = 说不出百分比（那就只转圈，但仍然说在干什么）
  final double? fraction;

  const LongTaskProgress(this.step, [this.fraction]);
}

class LongTaskDialog extends StatelessWidget {
  final ValueListenable<LongTaskProgress?> progress;
  final String title;

  const LongTaskDialog({super.key, required this.progress, required this.title});

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(title),
          content: ValueListenableBuilder<LongTaskProgress?>(
            valueListenable: progress,
            builder: (_, value, _) =>
                Column(mainAxisSize: MainAxisSize.min, children: [
              LinearProgressIndicator(
                  value: value?.fraction, color: AppColors.accentBlue),
              const SizedBox(height: AppSpacing.md),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(value?.step ?? '准备中',
                    style: const TextStyle(
                        fontSize: AppFontSize.body,
                        color: AppColors.textSecondary)),
              ),
            ]),
          ),
        ),
      );
}
