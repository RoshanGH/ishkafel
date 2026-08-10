import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/miaoa/miaoa_auth_service.dart';

/// 登录 miaoa：手机号 → 验证码 → 完成。
///
/// 为什么值得做进 app：CLI 支持 `--phone` / `--code` 两步走且不需要浏览器，
/// 而此前界面上写的是「请在终端运行 miaoa auth login」——让用户离开这个 app
/// 去敲命令，不是商业软件该有的样子。
///
/// **凭据不经我们的手保存**：手机号与验证码只活在这个表单的内存里，转发给
/// CLI 之后就没了；token 由 CLI 自己存自己续（见 [MiaoaAuthService]）。
class MiaoaLoginSheet extends StatefulWidget {
  final MiaoaAuthService service;

  /// 重新获取验证码的冷却秒数。短信是有成本的，也别让用户狂点
  final int resendCooldownSeconds;

  const MiaoaLoginSheet({
    super.key,
    required this.service,
    this.resendCooldownSeconds = 60,
  });

  /// 登录成功返回 true，取消或失败返回 null
  static Future<bool?> show(BuildContext context, MiaoaAuthService service) =>
      showDialog<bool>(
        context: context,
        builder: (_) => Dialog(
          backgroundColor: AppColors.surfaceRaised,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.lg)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: MiaoaLoginSheet(service: service),
          ),
        ),
      );

  @override
  State<MiaoaLoginSheet> createState() => _MiaoaLoginSheetState();
}

class _MiaoaLoginSheetState extends State<MiaoaLoginSheet> {
  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _codeFocus = FocusNode();

  /// 验证码发出去了没。发出去之后才显示验证码输入框——一上来就摆两个空框，
  /// 用户不知道该先填哪个
  bool _codeSent = false;
  bool _busy = false;
  String? _error;
  String? _notice;
  int _cooldown = 0;
  Timer? _cooldownTimer;

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _phone.dispose();
    _code.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  bool get _phoneOk => normalizePhone(_phone.text) != null;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('登录 miaoa',
                style: TextStyle(
                    fontSize: AppFontSize.title,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary)),
            const SizedBox(height: 6),
            const Text('用注册 miaoa 时的手机号收一条验证码。登录状态由 miaoa 命令行'
                '工具保存，本应用不会留存你的手机号或验证码。',
                style: TextStyle(
                    fontSize: AppFontSize.caption,
                    height: 1.5,
                    color: AppColors.textSecondary)),
            const SizedBox(height: AppSpacing.lg),
            _phoneField(),
            if (_codeSent) ...[
              const SizedBox(height: AppSpacing.md),
              _codeField(),
            ],
            if (_error != null) _banner(_error!, AppColors.red),
            if (_error == null && _notice != null)
              _banner(_notice!, AppColors.green),
            const SizedBox(height: AppSpacing.lg),
            _actions(),
          ],
        ),
      );

  Widget _phoneField() => TextField(
        key: const Key('login-phone'),
        controller: _phone,
        enabled: !_busy,
        autofocus: true,
        keyboardType: TextInputType.phone,
        // 11 位就够了；粘贴带横杠空格的号码由 normalizePhone 兜住
        inputFormatters: [LengthLimitingTextInputFormatter(20)],
        style: const TextStyle(color: AppColors.textPrimary),
        decoration: _decoration('手机号', '11 位手机号'),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _codeSent ? null : _requestCode(),
      );

  Widget _codeField() => TextField(
        key: const Key('login-code'),
        controller: _code,
        enabled: !_busy,
        autofocus: true,
        focusNode: _codeFocus,
        keyboardType: TextInputType.number,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(8),
        ],
        style: const TextStyle(color: AppColors.textPrimary),
        decoration: _decoration('验证码', '短信里的数字'),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _login(),
      );

  InputDecoration _decoration(String label, String hint) => InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: const TextStyle(color: AppColors.textSecondary),
        hintStyle: const TextStyle(color: AppColors.textTertiary),
        filled: true,
        fillColor: AppColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: AppColors.border),
        ),
      );

  Widget _banner(String text, Color color) => Padding(
        padding: const EdgeInsets.only(top: AppSpacing.md),
        child: Text(text,
            key: const Key('login-message'),
            style: TextStyle(
                fontSize: AppFontSize.caption, height: 1.5, color: color)),
      );

  Widget _actions() => Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          const SizedBox(width: AppSpacing.sm),
          if (_codeSent)
            TextButton(
              key: const Key('login-resend'),
              onPressed: _busy || _cooldown > 0 ? null : _requestCode,
              child: Text(_cooldown > 0 ? '重新获取（$_cooldown s）' : '重新获取'),
            ),
          if (_codeSent) const SizedBox(width: AppSpacing.sm),
          FilledButton(
            key: const Key('login-primary'),
            onPressed: _busy || !_primaryEnabled ? null : _primaryAction,
            child: _busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text(_codeSent ? '登录' : '获取验证码'),
          ),
        ],
      );

  bool get _primaryEnabled =>
      _codeSent ? _code.text.trim().isNotEmpty : _phoneOk;

  void _primaryAction() => _codeSent ? _login() : _requestCode();

  Future<void> _requestCode() async {
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    final result = await widget.service.requestCode(phone: _phone.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.ok) {
        _codeSent = true;
        _notice = result.message;
        _startCooldown();
      } else {
        _error = result.message;
      }
    });
    if (result.ok) _codeFocus.requestFocus();
  }

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await widget.service
        .completeLogin(phone: _phone.text, code: _code.text);
    if (!mounted) return;
    if (result.ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _error = result.message;
      // 验证码过期就把它清掉：留在框里只会被再提交一次
      if (result.message.contains('过期')) _code.clear();
    });
  }

  void _startCooldown() {
    _cooldownTimer?.cancel();
    _cooldown = widget.resendCooldownSeconds;
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      setState(() {
        _cooldown--;
        if (_cooldown <= 0) timer.cancel();
      });
    });
  }
}
