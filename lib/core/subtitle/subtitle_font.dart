import 'dart:io';

import 'package:path/path.dart' as p;

/// 烧进成片的字幕用哪一份字体。
///
/// ## 为什么必须自带字体，不能用系统的
///
/// 苹方（PingFang SC）是 Apple 的系统字体，微软雅黑是微软向北大方正授权的。
/// 两者的许可都只覆盖「**在本系统上显示和打印内容**」——都没有授予
/// 「把渲染结果烧进对外交付的商业成片」这项权利。
///
/// 而这个软件的出口正是**要交给客户的片子**：字幕是烧进画面像素的，
/// 还要矩阵导出批量产出。这是教科书级的「字体商业使用」，「系统自带」
/// 不等于「可商用」。
///
/// 换成 **Noto Sans SC**（与思源黑体同源，SIL Open Font License 1.1）：
/// 明确允许商业使用、嵌入产品、随软件分发、渲染输出。
/// 许可原文随字体一起分发（`assets/fonts/LICENSE-NotoSansSC.txt`），
/// 这是 OFL 的要求。
///
/// 字重取 Medium 而不是 Bold：出图比过，Medium 的字重与字宽最贴近原来的
/// 苹方 Semibold，Bold 明显更粗（笔画挤、字怀小），换上去人一眼就看得出
/// 「字变粗了」。
abstract final class SubtitleFont {
  /// 字体文件名（三处布局下都叫这个）
  static const String fileName = 'NotoSansSC-Medium.otf';

  /// PostScript 名——AppKit / CoreText 注册之后按这个名字取字体
  static const String postScriptName = 'NotoSansSC-Medium';

  /// 渲染规则版本。**换字体等于换渲染规则，必须进缓存指纹。**
  ///
  /// 不进的话，盘上那些用苹方渲过的 PNG 指纹没变、会被原样取出来复用——
  /// 用户装了新版，导出来的还是旧字体的图，而哪儿都不报错。
  /// 这正是 CLAUDE.md 那条「缓存按内容指纹，改了规则就要改指纹」。
  static const String renderRevision = 'noto-medium-1';

  /// 找到字体文件。找不到返回 null。
  ///
  /// **调用方必须失败并点名，不许退回系统字体**——那等于把刚解决掉的授权
  /// 问题又放回去，而且成片会静默变样（换个字体，交付出去的片子就不一样了，
  /// 而没有任何地方会报错）。
  ///
  /// 三种布局都要认，因为 GUI 和 CLI 跑在完全不同的位置上：
  /// 1. `ISHKAFEL_SUBTITLE_FONT` —— 显式指定（测试与排查用）
  /// 2. 打包版：`<app>.app/Contents/Resources/fonts/`
  ///    —— GUI 的可执行文件在 `Contents/MacOS/`，CLI 在
  ///    `Contents/Resources/cli/<架构>/bundle/bin/`，两边都是往上找到 `.app`
  ///    再进 `Resources/fonts`，所以同一段逻辑管两种
  /// 3. 开发期：从当前目录逐级往上找 `assets/fonts/`
  ///    —— `flutter run` / `dart run` / `flutter test` 的工作目录都在仓库内
  static File? locate({
    Map<String, String>? env,
    String? executablePath,
    Directory? workingDir,
    bool Function(String path)? exists,
  }) {
    final e = env ?? Platform.environment;
    final probe = exists ?? (path) => File(path).existsSync();

    final explicit = e['ISHKAFEL_SUBTITLE_FONT'];
    if (explicit != null && explicit.trim().isNotEmpty) {
      final path = explicit.trim();
      return probe(path) ? File(path) : null;
    }

    for (final dir in searchDirs(
      executablePath: executablePath ?? Platform.resolvedExecutable,
      workingDir: workingDir ?? Directory.current,
    )) {
      final candidate = p.join(dir, fileName);
      if (probe(candidate)) return File(candidate);
    }
    return null;
  }

  /// 按优先级列出候选目录（纯函数，便于逐项钉住）
  static List<String> searchDirs({
    required String executablePath,
    required Directory workingDir,
  }) {
    final dirs = <String>[];

    // 打包版：从可执行文件一路往上找 `.app`
    final bundle = _enclosingAppBundle(executablePath);
    if (bundle != null) {
      dirs.add(p.join(bundle, 'Contents', 'Resources', 'fonts'));
    }

    // 可执行文件旁边的 fonts/（Windows 的平铺布局将来走这条，macOS 上无害）
    dirs.add(p.join(p.dirname(executablePath), 'fonts'));

    // 开发期：从工作目录逐级往上找仓库根
    for (var dir = workingDir.absolute.path;; dir = p.dirname(dir)) {
      dirs.add(p.join(dir, 'assets', 'fonts'));
      if (p.dirname(dir) == dir) break;
    }
    return dirs;
  }

  /// 包住这个可执行文件的 `.app` 目录；不在任何 bundle 里就返回 null
  static String? _enclosingAppBundle(String executablePath) {
    for (var dir = p.dirname(executablePath);; dir = p.dirname(dir)) {
      if (p.extension(dir) == '.app') return dir;
      if (p.dirname(dir) == dir) return null;
    }
  }

  /// 找不到时说人话：说清缺什么、为什么非要它、人能做什么
  static String get missingMessage =>
      '找不到字幕字体 $fileName，这一版字幕渲染不出来。\n'
      '字幕必须用随包分发的 Noto Sans SC（SIL OFL，可商用）——'
      '系统自带的苹方/微软雅黑没有授予「把渲染结果烧进对外交付的成片」'
      '这项权利，所以这里不会退回系统字体。\n'
      '开发期：确认仓库里有 assets/fonts/$fileName；'
      '打包版：确认 <app>/Contents/Resources/fonts/$fileName 在包里'
      '（由 scripts/package_macos.sh 放进去）。'
      '也可以用环境变量 ISHKAFEL_SUBTITLE_FONT 显式指定一份。';
}
