import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../core/ffmpeg/media_tools_locator.dart';

/// 运行环境探测结果：null 表示尚未探测（测试或未接线场景），不展示横幅；
/// main.dart 启动时用真实 preflight 结果 override。
final mediaToolsStatusProvider = Provider<MediaToolsStatus?>((ref) => null);

/// 常驻提示横幅：环境类问题不能只写日志或弹一次性 SnackBar，
/// 必须在列表页持续可见，用户才知道该去做什么。
class NoticeBanner extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String message;

  const NoticeBanner({
    super.key,
    required this.icon,
    required this.color,
    required this.message,
  });

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                    fontSize: 12, height: 1.4, color: AppColors.textPrimary),
              ),
            ),
          ],
        ),
      );
}

/// 列表页顶部的环境提示区：把「装不了/跑不了」的前置条件常驻展示
class EnvironmentBanners extends ConsumerWidget {
  const EnvironmentBanners({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mediaTools = ref.watch(mediaToolsStatusProvider);
    final banners = <Widget>[
      if (mediaTools != null && !mediaTools.isReady)
        NoticeBanner(
          icon: Icons.error_outline,
          color: AppColors.red,
          message: '未检测到视频处理组件（${mediaTools.missingTools.join('、')}），'
              '导入与分析都无法进行。请在终端执行 brew install ffmpeg 安装后重启本应用。',
        ),
    ];
    if (banners.isEmpty) return const SizedBox.shrink();
    return Column(mainAxisSize: MainAxisSize.min, children: banners);
  }
}
