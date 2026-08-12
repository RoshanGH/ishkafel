import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/agent_skill/agent_skill_doc.dart';
import '../../core/agent_skill/skill_installer.dart';
import 'settings_providers.dart';
import 'settings_widgets.dart';

/// 「Agent 说明书」卡片。
///
/// 补的是最后一个缺口：装了 app、装了命令行工具之后，Agent 知道**能调什么**，
/// 还不知道**怎么用才做得出能用的片子**。装进用户级技能目录，之后在任意
/// 文件夹干活都生效。
class AgentSkillCard extends ConsumerStatefulWidget {
  /// 测试注入用
  final SkillInstaller? installer;

  const AgentSkillCard({super.key, this.installer});

  @override
  ConsumerState<AgentSkillCard> createState() => _AgentSkillCardState();
}

class _AgentSkillCardState extends ConsumerState<AgentSkillCard> {
  late SkillInstaller _installer;
  late SkillStatus _status;
  bool _busy = false;
  String? _message;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _installer = widget.installer ??
        SkillInstaller.forCurrentUser(
            markdown: agentSkillMarkdown, version: appVersion);
    _status = _installer.inspect();
  }

  Future<void> _install() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    final result = await _installer.install();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _failed = !result.ok;
      _message = result.message;
      _status = _installer.inspect();
    });
  }

  Future<void> _uninstall() async {
    setState(() => _busy = true);
    final removed = await _installer.uninstall();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _failed = removed == 0;
      _message = removed > 0 ? '已移除 $removed 份' : '没有可移除的';
      _status = _installer.inspect();
    });
  }

  @override
  Widget build(BuildContext context) => SettingsCard(
        title: 'Agent 说明书',
        children: [
          for (final target in _installer.targets)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: SettingsRow(
                label: target.agent,
                content: StatusDot(
                    ok: _status.installed.contains(target),
                    text: _textFor(target)),
              ),
            ),
          const SizedBox(height: AppSpacing.xs),
          SettingsNote(_explain),
          if (_message != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(_message!,
                style: TextStyle(
                    fontSize: AppFontSize.caption,
                    height: 1.6,
                    color: _failed ? AppColors.orange : AppColors.green)),
          ],
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton(
                  onPressed: _busy ? null : _install,
                  child: Text(_busy ? '安装中…' : _actionLabel),
                ),
                if (_status.anyPresent) ...[
                  const SizedBox(width: AppSpacing.sm),
                  TextButton(
                      onPressed: _busy ? null : _uninstall,
                      child: const Text('移除')),
                ],
              ],
            ),
          ),
        ],
      );

  String _textFor(SkillTarget target) {
    if (_status.installed.contains(target)) return '已安装';
    // 「有更新」和「未安装」要分开：前者是手上那份会把 Agent 带偏，
    // 后者只是还没有
    if (_status.outdated.contains(target)) return '有更新';
    return '未安装';
  }

  String get _actionLabel => _status.allCurrent
      ? '重新安装'
      : (_status.anyPresent ? '更新' : '安装');

  String get _explain => _status.outdated.isNotEmpty
      ? '手上那份是旧版本的说明书。命令变过之后，Agent 会照着旧文档去调新命令——'
          '点「更新」换成这一版的。'
      : '装进 ~/.claude/skills 与 ~/.codex/skills，**在任意文件夹都生效**——'
          '不用把这个项目的源码给谁。装完直接跟 Agent 说「用 ishkafel 翻新这条片子」。';
}
