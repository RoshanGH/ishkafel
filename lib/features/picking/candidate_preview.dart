import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/log/app_log.dart';
import '../../core/miaoa/miaoa_content_service.dart';
import '../../core/playback/playback_gate.dart';

/// 试看一条候选素材。
///
/// 光看首帧缩略图挑不出东西：同一个货架、同一只手，静止的一帧几乎分不出差别，
/// 而替换进成片的是这段**画面在动**的三秒。
typedef CandidatePreviewOpener = Future<void> Function(
    BuildContext context, CandidateMaterial material);

/// 真实实现：弹一个居中的竖屏播放浮层。测试注入假实现，免得碰 libmpv。
Future<void> showCandidatePreview(
  BuildContext context,
  CandidateMaterial material,
) async {
  final url = material.previewUrl;
  if (url == null || url.isEmpty) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
        content: Text('这条素材没有可播放的地址，无法试看')));
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (_) => _PreviewDialog(url: url, name: material.name),
  );
}

class _PreviewDialog extends StatefulWidget {
  final String url;
  final String name;

  const _PreviewDialog({required this.url, required this.name});

  @override
  State<_PreviewDialog> createState() => _PreviewDialogState();
}

class _PreviewDialogState extends State<_PreviewDialog> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);

  /// 与时间线播放器同一道保险：还没打开完就关掉浮层，直接销毁会在 mpv 跑
  /// loadlist 的当口抽掉它的配置，整个进程 abort
  final PlaybackGate _gate = PlaybackGate();
  String? _error;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      await _gate.run(() => _player.open(Media(widget.url)));
    } catch (e) {
      AppLog.warn('候选素材试看失败：$e');
      if (mounted) setState(() => _error = '这条素材播不出来，可能是预览地址已过期');
    }
  }

  @override
  void dispose() {
    _gate.close(_player.dispose);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
        backgroundColor: AppColors.surfaceRaised,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg)),
        child: ConstrainedBox(
          // 素材是竖屏（9:16），窄一点才不浪费横向空间
          constraints: const BoxConstraints(maxWidth: 380, maxHeight: 760),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md, AppSpacing.md, AppSpacing.sm, AppSpacing.sm),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(widget.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: AppFontSize.body)),
                    ),
                    IconButton(
                      key: const Key('candidate-preview-close'),
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close, size: 18),
                      color: AppColors.textSecondary,
                    ),
                  ],
                ),
              ),
              AspectRatio(
                aspectRatio: 9 / 16,
                child: _error == null
                    ? Video(controller: _controller)
                    : Center(
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpacing.lg),
                          child: Text(_error!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: AppColors.orange,
                                  fontSize: AppFontSize.body)),
                        ),
                      ),
              ),
            ],
          ),
        ),
      );
}
