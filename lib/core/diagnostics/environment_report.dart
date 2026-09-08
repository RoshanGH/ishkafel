import 'dart:io';

import '../ai/ai_credentials.dart';
import '../miaoa/miaoa_gateway.dart';
import '../build_mode.dart';
import '../ffmpeg/media_tools_locator.dart';
import '../ffmpeg/process_runner.dart';
import '../audio/vocal_separator.dart';

/// 子进程执行签名（与 [ProcessRunner] 同型，这里另起别名只为让测试的替身
/// 声明读起来直白）
typedef ProcessRunnerLike = Future<ProcessResult> Function(
    String executable, List<String> args);

/// 单个外部工具的体检结果（不可变）
class ToolHealth {
  final String name;

  /// 解析到的绝对路径；null 表示没找到
  final String? path;

  /// 版本首行；null 表示装了但没读出来（不等于未安装）
  final String? version;

  /// 未安装时该怎么办；已安装时为 null
  final String? hint;

  const ToolHealth({
    required this.name,
    this.path,
    this.version,
    this.hint,
  });

  bool get installed => path != null;
}

/// 运行环境体检报告（不可变）。
///
/// 硬性约束：**任何字段都不含凭据原文**。设置页是最容易被截图外发的一页，
/// 只报「有没有配」，不报「配的是什么」。
class EnvironmentReport {
  final List<ToolHealth> tools;
  final bool credentialsReady;
  final String? credentialsHint;

  EnvironmentReport({
    required List<ToolHealth> tools,
    required this.credentialsReady,
    this.credentialsHint,
  }) : tools = List.unmodifiable(tools);
}

/// 采集运行环境体检报告。
///
/// 存在的理由：本项目反复踩过同一个坑——GUI 启动的进程 PATH 里没有
/// Homebrew 目录，ffmpeg「明明装了」却调不起来。把解析到的真实路径摆在
/// 界面上，用户（和排查问题的人）一眼就能确认到底找没找到。
class EnvironmentProbe {
  /// ffmpeg / ffprobe 的解析结果。**每次体检都重新要一遍**，不能存成一个
  /// 启动时算好的值——用户在 app 开着的时候装好工具，体检要当场认出来
  final MediaToolsStatus Function() resolveMediaTools;

  final String? Function() resolveMiaoa;

  /// 人声分离工具的路径解析（可选项，找不到返回 null）
  final String? Function() resolveSeparator;
  final AiCredentials credentials;
  final ProcessRunnerLike run;

  /// 测试注入用：flutter test 的 VM 永远是 debug 模式，不注入的话
  /// 正式版文案那条分支在测试里永远走不到
  final bool debugBuild;

  const EnvironmentProbe({
    required this.resolveMediaTools,
    required this.resolveMiaoa,
    required this.resolveSeparator,
    required this.credentials,
    required this.run,
    this.debugBuild = isDebugBuild,
  });

  Future<EnvironmentReport> collect() async {
    final mediaTools = resolveMediaTools();
    final miaoaPath = resolveMiaoa();
    final specs = <(String, String?, List<String>)>[
      (MediaToolsLocator.ffmpeg, mediaTools.ffmpegPath, const ['-version']),
      (MediaToolsLocator.ffprobe, mediaTools.ffprobePath, const ['-version']),
      ('miaoa', miaoaPath, const ['--version']),
      ('audio-separator', resolveSeparator(), const ['--version']),
    ];

    final tools = <ToolHealth>[];
    for (final (name, path, args) in specs) {
      if (path == null) {
        tools.add(ToolHealth(name: name, hint: missingToolMessage(name)));
        continue;
      }
      // 路径已解析到才起进程：对不存在的可执行文件起进程只会白等一次 ENOENT
      tools.add(ToolHealth(
          name: name, path: path, version: await _readVersion(path, args)));
    }

    return EnvironmentReport(
      tools: tools,
      credentialsReady: credentials.isComplete,
      credentialsHint: credentials.isComplete
          ? null
          : debugBuild
              // 调试版本就不含凭据，让用户去找同事重新打包是把他引错方向
              ? '当前是开发调试版，本就不含云端 AI 凭据。日常使用请打开正式打包的版本。'
              : '云端 AI 凭据不完整，无法进行语音识别与画面打标。'
                  '请联系分发这个版本的同事重新打包。',
    );
  }

  /// 版本首行即可；`-version` 会吐出整段编译配置，全灌进界面只会淹没重点。
  /// 读失败返回 null——路径实实在在解析到了，标成未安装会把人引去重装。
  Future<String?> _readVersion(String path, List<String> args) async {
    try {
      final result = await run(path, args);
      final line = '${result.stdout}'.split('\n').first.trim();
      return line.isEmpty ? null : line;
    } catch (_) {
      return null;
    }
  }
}

/// 生产环境的默认采集器（miaoa 路径解析未命中时回退裸名，这里要还原成 null）
EnvironmentProbe defaultEnvironmentProbe({
  required MediaToolsStatus Function() resolveMediaTools,
  required AiCredentials credentials,
  ProcessRunnerLike? run,
}) =>
    EnvironmentProbe(
      resolveMediaTools: resolveMediaTools,
      resolveMiaoa: MiaoaGateway.installedPath,
      resolveSeparator: () {
        final resolved = resolveVocalSeparatorBinary();
        return resolved == 'audio-separator' ? null : resolved;
      },
      credentials: credentials,
      run: run ?? systemProcessRunner,
    );
