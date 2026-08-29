import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../log/app_log.dart';
import 'analysis_pipeline.dart';

/// 分析产物（ASR 句子 + 切点）按**源文件内容**缓存。
///
/// **为什么必须缓存**：语义切分是 LLM 干的、有随机性——真机上同一条片子
/// 导入三次切出 3 / 4 / 5 个单元。后果有两个：
///
/// - 方案文件不能跨任务复用：`unit 2 shot 3` 这个坐标在新任务里指向了
///   别的画面。重新导入一次，之前挑素材的工作全作废
/// - 「1:1 复刻」打折扣：3 个单元和 5 个单元切出来的边界不一样
///
/// 顺带省掉一次 ASR + LLM——那是真金白银，一条 75 秒的片子要几毛钱。
///
/// **只缓存与源文件有关的东西**：标签依赖标签组，换了标签组就该重打，
/// 所以不在这里。
class PreparedCache {
  final Directory dataDir;

  const PreparedCache(this.dataDir);

  Directory get _dir => Directory(p.join(dataDir.path, 'prepared'));

  File _fileFor(String print) => File(p.join(_dir.path, '$print.json'));

  /// 取。没有、坏了、指纹算不出来，一律返回 null——重算一次的代价，
  /// 远小于把另一条片子的切分安到这条上
  PreparedAnalysis? load(String? sourcePrint) {
    if (sourcePrint == null || sourcePrint.isEmpty) return null;
    try {
      final f = _fileFor(sourcePrint);
      if (!f.existsSync()) return null;
      return PreparedAnalysis.tryFromJson(jsonDecode(f.readAsStringSync()));
    } catch (e) {
      AppLog.warn('分析产物缓存读不动（$sourcePrint）：$e');
      return null;
    }
  }

  void save(String? sourcePrint, PreparedAnalysis prepared) {
    if (sourcePrint == null || sourcePrint.isEmpty) return;
    try {
      final f = _fileFor(sourcePrint);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode(prepared.toJson()));
    } catch (e) {
      // 存不下只是下次要重算，不该让这次导入失败
      AppLog.warn('分析产物缓存写不进（$sourcePrint）：$e');
    }
  }
}
