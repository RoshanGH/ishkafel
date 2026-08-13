import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  /// 复制全文。装进技能目录只对认那个目录的 Agent 有用；**文本谁都认**
  Future<void> _copy() async {
    await Clipboard.setData(
        ClipboardData(text: _installer.markdownForSharing));
    if (!mounted) return;
    setState(() {
      _failed = false;
      _message = '说明书全文已复制。粘给任何 Agent 都行——'
          'Claude 桌面版、Cursor、Warp、别家的 CLI，它认字就能照做';
    });
  }

  /// 存成 .md 文件，方便发给别人（微信、邮件、放进项目里）
  Future<void> _saveFile() async {
    try {
      final file = File(
          '${Platform.environment['HOME'] ?? '.'}/Desktop/ishkafel-说明书.md');
      file.writeAsStringSync(_installer.markdownForSharing);
      if (!mounted) return;
      setState(() {
        _failed = false;
        _message = '已存到桌面：${file.path.split('/').last}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _message = '存不下来：$e';
      });
    }
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
            // Wrap 而不是 Row：四个按钮在窄一点的窗口里会挤爆
            child: Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton(
                  onPressed: _busy ? null : _install,
                  child: Text(_busy ? '安装中…' : _actionLabel),
                ),
                // 通用出口：不认技能目录的 Agent（Warp / Cursor / 各家桌面版
                // / 明天冒出来的新工具）穷举不完，但**文本谁都认**
                OutlinedButton(
                    onPressed: _busy ? null : _copy,
                    child: const Text('复制全文')),
                TextButton(
                    onPressed: _busy ? null : _saveFile,
                    child: const Text('存成文件')),
                if (_status.anyPresent)
                  TextButton(
                      onPressed: _busy ? null : _uninstall,
                      child: const Text('移除')),
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
      : '「安装」写进 ~/.claude/skills 与 ~/.codex/skills，在任意文件夹都生效。\n'
          '用别的 Agent（Cursor、Warp、各家桌面版…）就点「复制全文」，'
          '粘给它就行——说明书就是一份 Markdown，它认字就能照做。\n'
          '要发给同事就点「存成文件」，存到桌面上一个 .md，微信发过去即可。';
}
