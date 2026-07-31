import 'package:flutter/material.dart';

/// 已完成 layout 的单行文字缓存（LRU）。
///
/// 时间线每帧要画几十段文字：刻度标签、轨道标题、单元编号与台词、镜头编号。
/// 每段都新建 `TextPainter` + `TextSpan` + `TextStyle` 并重新 layout，而文字
/// layout 是重操作——实测单段约 35µs，几十段叠加就是每帧 1~2ms，且这些内容
/// 在两帧之间几乎从不变化（播放头移动并不改变任何一段文字）。
///
/// 键包含 maxWidth：同一段文字在不同可用宽度下的省略结果不同，不能混用。
class TextLayoutCache {
  TextLayoutCache({this.capacity = 256});

  /// 缓存上限。超出后按最久未使用淘汰并释放其原生资源。
  final int capacity;

  /// Dart 的 Map 保持插入顺序，命中时删除再插入即可实现 LRU
  final _entries = <String, TextPainter>{};

  int get length => _entries.length;

  /// 取一段已排版好的文字；未命中则排版并存入。
  TextPainter acquire({
    required String text,
    required Color color,
    required double fontSize,
    double? maxWidth,
  }) {
    final key = '$fontSize|${color.toARGB32()}|${maxWidth ?? -1}|$text';
    final cached = _entries.remove(key);
    if (cached != null) {
      _entries[key] = cached; // 重新插入到队尾，标记为最近使用
      return cached;
    }

    final painter = TextPainter(
      text: TextSpan(
          text: text, style: TextStyle(color: color, fontSize: fontSize)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    );
    // maxWidth 一律夹紧到非负：TextPainter.layout 内部的 clampDouble 断言
    // min <= max，负数会在绘制中途抛出，让本帧后续所有绘制丢失
    painter.layout(maxWidth: maxWidth == null || maxWidth < 0
        ? double.infinity
        : maxWidth);

    _entries[key] = painter;
    if (_entries.length > capacity) {
      final oldestKey = _entries.keys.first;
      _entries.remove(oldestKey)?.dispose();
    }
    return painter;
  }

  /// 释放全部缓存（页面卸载时调用）
  void clear() {
    for (final painter in _entries.values) {
      painter.dispose();
    }
    _entries.clear();
  }
}
