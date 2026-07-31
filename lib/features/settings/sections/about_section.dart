import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../core/log/app_log.dart';
import '../settings_providers.dart';
import '../settings_widgets.dart';

/// 在访达中打开目录（注入点：测试不真的调起访达）
typedef DirectoryRevealer = Future<void> Function(Directory dir);

Future<void> _revealInFinder(Directory dir) async {
  await Process.run('open', [dir.path]);
}

final directoryRevealerProvider =
    Provider<DirectoryRevealer>((ref) => _revealInFinder);

/// 关于分区：版本号 + 数据目录。
///
/// 这两条不是装饰——出问题时，「你用的哪个版本」和「数据在哪」是排查的第一
/// 步。没有它们，同事只能截一张看不出版本的界面图过来。
class AboutSection extends ConsumerWidget {
  const AboutSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dataDir = ref.watch(dataDirProvider);
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.xl),
      children: [
        SettingsCard(
          title: 'ishkafel',
          children: [
            const SettingsRow(label: '版本', value: appVersion),
            const Divider(height: 1, color: AppColors.border),
            SettingsRow(
              label: '数据目录',
              value: dataDir?.path ?? '尚未初始化',
              trailing: dataDir == null
                  ? null
                  : TextButton(
                      key: const Key('settings-reveal-data-dir'),
                      onPressed: () => _reveal(context, ref, dataDir),
                      child: const Text('在访达中显示'),
                    ),
            ),
            const SettingsNote('任务数据、封面与分析中间产物都存放在这里。'
                '反馈问题时附上版本号，能省掉大半来回。'),
          ],
        ),
        const SettingsCard(
          title: '这个工具做什么',
          children: [
            SettingsNote('导入一条成片 → 按台词语义切分成单元、单元内再切视觉镜头 → '
                '按标签检索候选素材替换画面 → 矩阵导出多条变体。\n'
                '整个过程中台词与音频保持不变，替换的只是画面。'),
          ],
        ),
      ],
    );
  }

  Future<void> _reveal(
      BuildContext context, WidgetRef ref, Directory dir) async {
    try {
      await ref.read(directoryRevealerProvider)(dir);
    } catch (e) {
      AppLog.warn('打开数据目录失败：$e');
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法打开数据目录，可复制上面的路径手动前往。')));
    }
  }
}
