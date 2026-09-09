import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/subtitle/subtitle_style.dart';
import '../shared/preview_subtitle.dart';

/// 审片台预览画面上的实时字幕层。
///
/// **为什么字幕不再烧进预览切片**：原来替换镜头的字是 ffmpeg 烧进变速切片
/// 的，于是调一次字号、挪一次位置就要重渲一遍、换一次播放源——转圈几秒、
/// 播放头弹回片头。用户原话：「我调整字幕样式的时候应该实时显示，而不是
/// 每次都要有一个加载的动效，然后跳转到第一帧，这个跳转太煞笔了」。
/// 现在预览这一层由 Flutter 现画，改样式零 ffmpeg、零换源、零跳帧；
/// 导出仍旧照 spec 烧录（见 `export_runner`）。
///
/// 哪一刻出哪句字、哪些镜头压根不出，全部交给
/// [previewSubtitleAt]（`core/subtitle/preview_subtitle_at.dart`）——
/// 这里只管画。
class PreviewSubtitleLayer extends StatefulWidget {
  /// 播放位置（**成片**毫秒）
  final ValueListenable<int> positionMs;

  /// 这一刻该显示的那行字；null = 不出字
  final String? Function(int composedMs) textAt;

  final SubtitleStyle style;

  /// 点字幕 = 打开样式面板（操作就在字幕上，不用去顶栏找）
  final VoidCallback? onTap;

  /// 上下拖字幕直接调位置，松手时落盘
  final ValueChanged<double>? onDragEnd;

  const PreviewSubtitleLayer({
    super.key,
    required this.positionMs,
    required this.textAt,
    required this.style,
    this.onTap,
    this.onDragEnd,
  });

  @override
  State<PreviewSubtitleLayer> createState() => _PreviewSubtitleLayerState();
}

class _PreviewSubtitleLayerState extends State<PreviewSubtitleLayer> {
  /// 拖动中的临时位置（还没落盘）
  double? _dragRatio;

  @override
  Widget build(BuildContext context) {
    // 只让这一层跟着播放位置重建：位置每秒变三十次，走 setState 会连带
    // 重建整个播放面板（含视频区域）
    return ValueListenableBuilder<int>(
      valueListenable: widget.positionMs,
      builder: (context, ms, _) {
        final text = widget.textAt(ms);
        if (text == null || text.trim().isEmpty) {
          return const SizedBox.shrink();
        }
        return PreviewSubtitle(
          text: text,
          style: widget.style,
          onTap: widget.onTap,
          dragRatio: _dragRatio,
          onDragRatio: widget.onDragEnd == null
              ? null
              : (r) => setState(() => _dragRatio = r),
          onDragEnd: widget.onDragEnd == null
              ? null
              : (r) {
                  setState(() => _dragRatio = null);
                  widget.onDragEnd!(r);
                },
        );
      },
    );
  }
}
