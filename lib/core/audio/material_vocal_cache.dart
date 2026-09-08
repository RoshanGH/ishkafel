import 'dart:io';

import 'package:path/path.dart' as p;

import '../log/app_log.dart';
import 'vocal_separator.dart';

/// 把**替换素材**分成人声与背景两路，按素材文件缓存，同一条只分离一次。
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
  Future<String?> vocalsOf(String materialPath) async =>
      (await separate(materialPath))?.vocalsPath;

  /// 返回这条素材的背景轨（水声、喷雾声、环境音；说话声已被分掉）。
  ///
  /// **背景轨原来是生成完就删掉的**——那时这条链路只要纯人声，一条 30MB 的
  /// 未压缩 WAV 躺着纯属占盘。现在「替换分镜放背景声」这一档要读它，
  /// 它就有了读者，于是留着（磁盘上的每一份数据都要有人读、有人删——
  /// 这两条现在都满足了：任务删掉时按缓存目录整片清）。
  Future<String?> backgroundOf(String materialPath) async =>
      (await separate(materialPath))?.backgroundPath;

  /// 分离一次，两路都拿到。**同一条素材只跑一次**：
  /// [VocalSeparator] 认已有产物，人声和背景是同一次分离的两个输出，
  /// 分别调两个方法不会跑第二遍
  Future<SeparatedAudio?> separate(String materialPath) async {
    final tool = separator;
    if (tool == null) return null;
    if (!File(materialPath).existsSync()) return null;
    try {
      return await tool.separate(
        audioPath: materialPath,
        // 同一条素材的产物固定落一处，[VocalSeparator] 自己会认已有结果
        outputDir: Directory(
            p.join(cacheDir.path, p.basenameWithoutExtension(materialPath))),
      );
    } catch (e) {
      AppLog.warn('素材分离失败（$materialPath）：$e');
      return null;
    }
  }
}
