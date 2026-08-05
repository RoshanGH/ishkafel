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
/// 走 `audio-separator` 命令行（BS-Roformer 模型，见 [model]）。
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

  /// 用的模型：BS-Roformer。
  ///
  /// **这个选择是用耳朵定的，不是用指标定的**。先用的是 MDX 系列
  /// （UVR-MDX-NET-Inst_HQ_3 / Voc_FT / Kim_Vocal_2），人声轨里明显留着背景
  /// 音乐。而 RMS、频段能量、包络相关性这些指标在几个模型之间的差异都在
  /// -30dB 以下——**根本测不出来**：压在人声下面 20~30dB 的音乐在总能量里
  /// 只占千分之几，人耳却一听一个准。
  ///
  /// 代价（M1 Pro、96 秒素材实测）：模型 610MB（MDX 是 64MB），分离 83 秒
  /// （MDX 是 15 秒）。都是一次性的：模型只下一次，分离跑在导入后本来就要
  /// 几分钟的分析流程里。质量在这件事上省不得——分不干净，换配乐就等于两首
  /// 曲子一起响。
  ///
  /// 也试过 Mel-Band Roformer（961MB / 94 秒）：更大更慢，没有理由选它。
  static const String model = 'model_bs_roformer_ep_368_sdr_12.9628.ckpt';

  /// 模型的短标记，进产物文件名——换模型后能自动重算，不会复用旧产物
  static String get modelTag =>
      model.contains('roformer') ? 'roformer' : 'mdx';

  /// 攒批与分段。MDX 与 MDXC（Roformer 走这一支）各有各的参数名，两套都给：
  /// 不认的那套会被忽略，换模型时不必跟着改调用点。
  ///
  /// 实测加大 batch 对 Roformer 没有帮助（1:22 vs 1:23，Apple GPU 已经吃满），
  /// 但对 MDX 有决定性影响（2 分 09 秒 → 15 秒），所以这两个值仍然要给。
  static const int batchSize = 8;
  static const int segmentSize = 512;

  /// 分离 [audioPath]，两条轨落到 [outputDir]。
  ///
  /// 已经分离过就直接复用（一次要一分多钟，重进任务不该再等一遍）。
  Future<SeparatedAudio> separate({
    required String audioPath,
    required Directory outputDir,
  }) async {
    outputDir.createSync(recursive: true);
    modelDir.createSync(recursive: true);

    // 文件名带上模型标记：换了模型就该重新分离，而不是把上一个模型的产物
    // 当成新结果接着用——那正是这次踩到的问题（旧模型分不干净）
    final stem = '${p.basenameWithoutExtension(audioPath)}-$modelTag';
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
      '--mdxc_batch_size', '$batchSize',
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
