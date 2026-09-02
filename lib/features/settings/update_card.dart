import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/app_version.dart';
import '../../core/update/release_manifest.dart';
import '../../core/update/update_config.dart';
import '../../core/update/update_service.dart';
import '../update/update_dialog.dart';
import 'settings_widgets.dart';

/// 「有新版本 → 点一下 → 装好重启」。
///
/// 为什么值得做：发到今天已经几十版，每一版都要重新发包、对方重新解压、
/// 重新装命令行、重新换说明书——**版本不一致会直接出事**（旧 CLI 调新参数、
/// 旧手册教不存在的命令，都撞过）。让软件自己升级，这些就都对得上了。
class UpdateCard extends StatefulWidget {
  /// 注入点：测试不真的联网、不真的替换 app
  final UpdateService? service;
  const UpdateCard({super.key, this.service});

  @override
  State<UpdateCard> createState() => _UpdateCardState();
}

class _UpdateCardState extends State<UpdateCard> {
  late final UpdateService _service = widget.service ?? UpdateService();
  UpdateState _state = const UpdateIdle();
  ReleaseManifest? _found;

  /// 查过一次没有新版本时，把这句话留在界面上——
  /// 点了按钮什么都不变，人会以为它坏了
  bool _checkedAndUpToDate = false;

  @override
  void initState() {
    super.initState();
    // 进设置就顺手查一次：查不到就静静地什么都不显示，不打扰
    if (UpdateConfig.enabled) unawaited(_check());
  }

  Future<void> _check() async {
    setState(() {
      _state = const UpdateChecking();
      _checkedAndUpToDate = false;
    });
    final found = await _service.check();
    if (!mounted) return;
    setState(() {
      _found = found;
      _state = found == null ? const UpdateIdle() : UpdateAvailable(found);
      _checkedAndUpToDate = found == null;
    });
  }

  /// 走**统一的那个对话框**——主界面顶栏点进来的也是它。
  /// 同一件事两处各写一套，迟早一处改了另一处没改
  Future<void> _install() async {
    final release = _found;
    if (release == null) return;
    await showUpdateDialog(context, release: release, service: _service);
    if (mounted) await _check();
  }

  @override
  Widget build(BuildContext context) {
    if (!UpdateConfig.enabled) {
      // 没配就整个不显示——不能摆一个点下去永远报错的按钮
      return const SizedBox.shrink();
    }
    return SettingsCard(
      title: '软件更新',
      children: [
        SettingsRow(
          label: '当前版本',
          value: appVersion,
          trailing: _trailing(),
        ),
        if (_state case UpdateAvailable(:final release)) ...[
          const Divider(height: 1, color: AppColors.border),
          _notes(release),
        ],
        if (_checkedAndUpToDate)
          const SettingsNote('已经是最新版本。'),
        const SettingsNote('更新会自动重启，并把命令行工具和 Agent 说明书'
            '一起更新到同一版——版本对不上是最难查的一类问题。'),
      ],
    );
  }

  Widget? _trailing() => switch (_state) {
        UpdateChecking() => const SizedBox(
            width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        UpdateAvailable(:final release) => FilledButton(
            key: const ValueKey('update-install'),
            onPressed: _install,
            child: Text('更新到 ${release.version}'),
          ),
        UpdateDownloading() || UpdateInstalling() => null,
        _ => TextButton(
            key: const ValueKey('update-check'),
            onPressed: _check,
            child: const Text('检查更新'),
          ),
      };

  Widget _notes(ReleaseManifest release) => Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${release.version} 改了什么',
                style: const TextStyle(
                    fontSize: AppFontSize.caption,
                    color: AppColors.textSecondary)),
            const SizedBox(height: AppSpacing.xs),
            Text(
              release.notes.trim().isEmpty ? '（这一版没写更新说明）' : release.notes.trim(),
              style: const TextStyle(
                  fontSize: AppFontSize.caption,
                  height: 1.5,
                  color: AppColors.textPrimary),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text('要下载 ${(release.sizeBytes / 1024 / 1024).toStringAsFixed(0)} MB',
                style: const TextStyle(
                    fontSize: AppFontSize.micro,
                    color: AppColors.textTertiary)),
          ],
        ),
      );
}
