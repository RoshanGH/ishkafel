import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:path/path.dart' as p;

import '../log/app_log.dart';
import 'vocal_separator.dart';

/// 把**替换素材**分离成纯人声，按素材文件缓存，同一条只分离一次。
///
/// 为什么需要它：整体替换的段落，声音来自那条素材，里面同样有背景音。
/// 在它上面铺配乐，素材自带的背景音和新配乐就是两首曲子一起响——跟原片那一路
/// 是同一个问题，只是音源换成了素材。原来这条路上没有分离，界面只能提示
/// 「装好工具后重新分析」，而空白任务根本没有原片可分析，那是条死路。
///
/// **只在真的铺了配乐的段落才会被调用**（见 [AudioTrackBuilder]）：分离是
/// 有损的（实测残差 -27dB），没换配乐的地方没必要先损一道。
class MaterialVocalCache {
  final VocalSeparator? separator;

  /// 分离产物落在哪儿。按素材文件名分子目录，任务删掉时可以整片清掉
  final Directory cacheDir;

  const MaterialVocalCache({required this.separator, required this.cacheDir});

  /// 返回这条素材的纯人声轨；**null 表示分不了**（没装工具或分离失败）。
  ///
  /// 分不了不是错误：调用方退回素材原声照常出片，只是配乐会和它叠在一起，
  /// 那件事由界面如实告知。这里绝不抛——一条素材分不了不该让整次导出失败。
  Future<String?> vocalsOf(String materialPath) async {
    final tool = separator;
    if (tool == null) return null;
    if (!File(materialPath).existsSync()) return null;
    try {
      final stems = await tool.separate(
        audioPath: materialPath,
        // 同一条素材的产物固定落一处，[VocalSeparator] 自己会认已有结果
        outputDir: Directory(
            p.join(cacheDir.path, p.basenameWithoutExtension(materialPath))),
      );
      return stems.vocalsPath;
    } catch (e) {
      AppLog.warn('素材人声分离失败（$materialPath）：$e');
      return null;
    }
  }
}

/// 把素材分离成纯人声的能力。**null 表示这台机器上分不了**（没装工具）——
/// 界面据此如实说明「配乐会和素材原声叠在一起」，而不是让用户对着一条
/// 听起来不对的预览发呆。缺省是 null，真实实现在 main.dart 里装配。
final materialSeparatorProvider =
    Provider<Future<String?> Function(String materialPath)?>((ref) => null);
