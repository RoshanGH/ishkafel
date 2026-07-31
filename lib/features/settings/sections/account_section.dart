import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/log/app_log.dart';
import '../../../core/miaoa/miaoa_account_service.dart';
import '../../../core/miaoa/miaoa_failure.dart';
import '../settings_providers.dart';
import '../settings_widgets.dart';

/// miaoa 账号分区：登录状态、租户、当前项目。
///
/// 只读不写——切换租户/项目、登录登出都由 miaoa CLI 完成，app 不代收凭据，
/// 也不去改 CLI 的本地上下文（那会让终端里正在进行的操作莫名其妙地变样）。
class AccountSection extends ConsumerWidget {
  const AccountSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(miaoaAccountProvider);
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.xl),
      children: [
        account.when(
          loading: () => const SettingsCard(children: [
            SettingsRow(label: '登录状态', value: '读取中…'),
          ]),
          // provider 内部已把异常收敛成 status.failure，这里兜住意外抛出
          error: (e, _) => SettingsCard(children: [
            SettingsErrorBlock(
                message: accountFailureGuidance(MiaoaFailureKind.unknown),
                onRetry: () => ref.invalidate(miaoaAccountProvider)),
          ]),
          data: (status) => _body(ref, status),
        ),
      ],
    );
  }

  Widget _body(WidgetRef ref, MiaoaAccountStatus? status) {
    if (status == null) {
      return const SettingsCard(
          children: [SettingsNote('本次运行未接入 miaoa 账号服务（通常只发生在测试环境）。')]);
    }
    final failure = status.failure;
    if (failure != null) {
      return SettingsCard(children: [
        SettingsErrorBlock(
            message: failure.message,
            onRetry: () => ref.invalidate(miaoaAccountProvider)),
      ]);
    }
    return status.loggedIn ? _LoggedIn(status: status) : const _LoggedOut();
  }
}

class _LoggedIn extends ConsumerWidget {
  final MiaoaAccountStatus status;

  const _LoggedIn({required this.status});

  @override
  Widget build(BuildContext context, WidgetRef ref) => SettingsCard(children: [
        SettingsRow(
          label: '登录状态',
          content: StatusDot(
              ok: true, text: '${status.maskedAccount ?? '已登录账号'} · 已登录'),
          trailing: TextButton(
            onPressed: () => ref.invalidate(miaoaAccountProvider),
            child: const Text('刷新'),
          ),
        ),
        const Divider(height: 1, color: AppColors.border),
        SettingsRow(label: '租户', value: status.tenantName),
        const Divider(height: 1, color: AppColors.border),
        SettingsRow(
          label: '当前项目',
          value: status.projectCount == null
              ? status.projectName
              : '${status.projectName ?? '未选择'}（${status.projectCount} 个可选）',
        ),
        const Divider(height: 1, color: AppColors.border),
        SettingsRow(label: '服务地址', value: status.endpoint),
        const SettingsNote('切换租户与项目请在终端使用 miaoa CLI 完成。'
            '本应用只读取上下文，不会替你改动它——否则终端里正在进行的操作会莫名变样。'),
      ]);
}

class _LoggedOut extends ConsumerWidget {
  const _LoggedOut();

  @override
  Widget build(BuildContext context, WidgetRef ref) => SettingsCard(children: [
        const SettingsRow(
          label: '登录状态',
          content: StatusDot(ok: false, text: '未登录'),
        ),
        const SizedBox(height: AppSpacing.sm),
        const Text('未登录时无法检索候选素材、也读不到标签组。请在终端运行下面这条命令完成登录'
            '（手机号 + 短信验证码），完成后点「刷新」。',
            style: TextStyle(
                fontSize: AppFontSize.body,
                height: 1.6,
                color: AppColors.textPrimary)),
        const SizedBox(height: AppSpacing.md),
        const _CommandBox(command: miaoaLoginCommand),
        const SizedBox(height: AppSpacing.md),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            onPressed: () => ref.invalidate(miaoaAccountProvider),
            child: const Text('刷新'),
          ),
        ),
      ]);
}

/// 命令行片段 + 一键复制。让用户照着屏幕手打一条命令是最容易出错的一步。
class _CommandBox extends StatefulWidget {
  final String command;

  const _CommandBox({required this.command});

  @override
  State<_CommandBox> createState() => _CommandBoxState();
}

class _CommandBoxState extends State<_CommandBox> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Expanded(
              child: SelectableText(widget.command,
                  style: const TextStyle(
                      fontSize: AppFontSize.body,
                      fontFamily: 'Menlo',
                      color: AppColors.accentBlueLight)),
            ),
            TextButton(
              key: const Key('settings-copy-login-command'),
              onPressed: _copy,
              child: Text(_copied ? '已复制' : '复制'),
            ),
          ],
        ),
      );

  Future<void> _copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.command));
      if (!mounted) return;
      setState(() => _copied = true);
    } catch (e) {
      // 剪贴板不可用时不能什么都不发生——用户会反复点同一个按钮
      AppLog.warn('复制登录命令失败：$e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('复制失败，请手动选中上面的命令复制。')));
    }
  }
}
