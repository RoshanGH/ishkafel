import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/log/app_log.dart';
import '../../core/playback/playback_gate.dart';
import '../picking/picking_providers.dart';

/// 审核页播放一条素材。
typedef ReviewPreviewOpener = Future<void> Function(
    BuildContext context, WidgetRef ref, int materialId,
    {required String name});

/// 真实实现：先把素材**落到本地**再播。
///
/// 不直接播签名地址——它隔天就 403，审核页要是播不出来，人就没法把关。
/// 走 [materialFetcherProvider]（与导出同一个缓存目录），已经落过的秒开，
/// 没落过的下完再播；这样**审核看到的和导出用的是同一个文件**。
Future<void> showReviewPreview(
  BuildContext context,
  WidgetRef ref,
  int materialId, {
  required String name,
}) async {
  final fetch = ref.read(materialFetcherProvider);
  if (fetch == null) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('素材下载器未就绪，播不了')));
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (_) => _ReviewPreviewDialog(
      name: name,
      resolve: () => fetch(materialId),
    ),
  );
}

class _ReviewPreviewDialog extends StatefulWidget {
  final String name;
  final Future<String> Function() resolve;

  const _ReviewPreviewDialog({required this.name, required this.resolve});

  @override
  State<_ReviewPreviewDialog> createState() => _ReviewPreviewDialogState();
}

class _ReviewPreviewDialogState extends State<_ReviewPreviewDialog> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);

  /// 与其余播放器同一道保险：还没打开完就关掉浮层，直接销毁会在 mpv 跑
  /// loadlist 的当口抽掉它的配置，整个进程 abort
  final PlaybackGate _gate = PlaybackGate();
  String? _error;
  bool _resolving = true;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final path = await widget.resolve();
      if (!mounted) return;
      setState(() => _resolving = false);
      await _gate.run(() => _player.open(Media(path)));
    } catch (e) {
      AppLog.warn('审核试看失败（${widget.name}）：$e');
      if (mounted) {
        setState(() {
          _resolving = false;
          _error = '这条素材取不下来：$e';
        });
      }
    }
  }

  @override
  void dispose() {
    _gate.run(_player.dispose);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
        backgroundColor: AppColors.surface,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360, maxHeight: 700),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpacing.sm),
                child: Text(widget.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: AppFontSize.caption,
                        color: AppColors.textSecondary)),
              ),
              Flexible(
                child: _error != null
                    ? Padding(
                        padding: const EdgeInsets.all(AppSpacing.lg),
                        child: Text(_error!,
                            style:
                                const TextStyle(color: AppColors.orange)))
                    : _resolving
                        ? const Padding(
                            padding: EdgeInsets.all(AppSpacing.xl),
                            child: Column(mainAxisSize: MainAxisSize.min,
                                children: [
                                  CircularProgressIndicator(),
                                  SizedBox(height: AppSpacing.sm),
                                  Text('正在取素材（首次要下载）…',
                                      style: TextStyle(
                                          fontSize: AppFontSize.caption,
                                          color: AppColors.textTertiary)),
                                ]))
                        : AspectRatio(
                            aspectRatio: 9 / 16,
                            child: Video(controller: _controller)),
              ),
              TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('关闭')),
            ],
          ),
        ),
      );
}
