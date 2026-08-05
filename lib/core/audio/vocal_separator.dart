import 'dart:io';

import 'package:path/path.dart' as p;

import '../ffmpeg/media_tools_locator.dart';
import '../ffmpeg/process_runner.dart';
import '../log/app_log.dart';

/// 分离出来的两条轨
class SeparatedAudio {
  /// 纯人声（口播）
  final String vocalsPath;

  /// 纯背景（原片自带的音乐/环境声）
  final String backgroundPath;

  const SeparatedAudio({required this.vocalsPath, required this.backgroundPath});
}

/// 把原片音频拆成「纯人声口播」与「纯背景音乐」两条轨。
///
/// **为什么必须真的分离**：产品要换掉背景音乐。不分离的话，新配乐只能叠在
/// 原声之上——原片自带的背景音还在，两首曲子一起响。
///
/// **但分离是有损的**：真机实测，人声轨 + 背景轨相加与原混音相减，残差在
/// -27dB（听得出来）。所以只有**真的换了配乐的段落**才用分离结果，其余段落
/// 一律用原混音，一个字节都不动。这条策略在混音那一层实现，本类只管分离。
///
/// 走 `audio-separator` 命令行（UVR MDX-Net 模型，onnxruntime）。
class VocalSeparator {
  final ProcessRunner run;

  /// 可执行文件路径（由 [resolveVocalSeparatorBinary] 解析）
  final String binary;

  /// 模型文件落地目录。**必须显式指定**：这个工具默认放 `/tmp`，
  /// 系统清理临时目录后每次都要重新下载几百兆。
  final Directory modelDir;

  const VocalSeparator({
    required this.modelDir,
    this.run = systemProcessRunner,
    this.binary = 'audio-separator',
  });

  /// 用的模型。UVR-MDX-NET-Inst_HQ_3 在口播 + 背景音这种素材上分离得干净，
  /// 是 UVR 社区里这一类任务的常用选择。
  static const String model = 'UVR-MDX-NET-Inst_HQ_3.onnx';

  /// 攒批与分段大小。真机实测（M1 Pro，96 秒素材）：
  /// 默认的 batch=1 / segment=256 要 2 分 09 秒，改成 8 / 512 只要 15 秒，
  /// 而两次输出逐样本相减的残差只有 -40dB（听不出差别）。
  static const int batchSize = 8;
  static const int segmentSize = 512;

  /// 分离 [audioPath]，两条轨落到 [outputDir]。
  ///
  /// 已经分离过就直接复用（分离一次十几秒，重进任务不该再等一遍）。
  Future<SeparatedAudio> separate({
    required String audioPath,
    required Directory outputDir,
  }) async {
    outputDir.createSync(recursive: true);
    modelDir.createSync(recursive: true);

    final stem = p.basenameWithoutExtension(audioPath);
    final vocals = File(p.join(outputDir.path, '$stem-人声.wav'));
    final background = File(p.join(outputDir.path, '$stem-背景.wav'));
    if (vocals.existsSync() &&
        background.existsSync() &&
        vocals.lengthSync() > 0 &&
        background.lengthSync() > 0) {
      return SeparatedAudio(
          vocalsPath: vocals.path, backgroundPath: background.path);
    }

    final result = await run(binary, [
      audioPath,
      '--model_filename', model,
      '--model_file_dir', modelDir.path,
      '--output_dir', outputDir.path,
      '--output_format', 'WAV',
      '--mdx_batch_size', '$batchSize',
      '--mdx_segment_size', '$segmentSize',
      // 输出文件名固定，省得去猜工具按模型名拼出来的那一长串
      '--custom_output_names',
      '{"Vocals": "$stem-人声", "Instrumental": "$stem-背景"}',
    ]);

    if (result.exitCode != 0) {
      throw VocalSeparationException(
          _friendlyError(result.exitCode, '${result.stderr}'));
    }
    if (!vocals.existsSync() || !background.existsSync()) {
      AppLog.warn('人声分离没有产出预期文件：${result.stdout}');
      throw const VocalSeparationException('人声分离没有产出音轨文件，请重试');
    }
    return SeparatedAudio(
        vocalsPath: vocals.path, backgroundPath: background.path);
  }

  /// 把命令行的失败翻译成用户能照做的中文
  static String _friendlyError(int exitCode, String stderr) {
    final lower = stderr.toLowerCase();
    if (lower.contains('no such file') || lower.contains('not found')) {
      return '未检测到人声分离工具，请先安装后重试';
    }
    if (lower.contains('connection') || lower.contains('timed out')) {
      return '下载分离模型失败，请检查网络后重试';
    }
    AppLog.warn('人声分离失败（exit=$exitCode）：$stderr');
    return '人声分离失败，请稍后重试';
  }
}

class VocalSeparationException implements Exception {
  final String message;
  const VocalSeparationException(this.message);
  @override
  String toString() => 'VocalSeparationException: $message';
}

/// `audio-separator` 的常见安装位置。
///
/// 与 miaoa 同一个坑：GUI 进程的 PATH 里没有用户级 bin 目录。`uv tool install`
/// 装到 `~/.local/bin`，pipx 也是。
final List<String> vocalSeparatorSearchDirs = List.unmodifiable([
  if (_home != null) '$_home/.local/bin',
  ...MediaToolsLocator.defaultSearchDirs,
]);

final String? _home = Platform.environment['HOME'];

final _locator = MediaToolsLocator(searchDirs: vocalSeparatorSearchDirs);

/// 解析可执行文件路径；找不到时回退裸名，让子进程照常抛出「未安装」
String resolveVocalSeparatorBinary({MediaToolsLocator? locator}) =>
    (locator ?? _locator).resolve('audio-separator') ?? 'audio-separator';
