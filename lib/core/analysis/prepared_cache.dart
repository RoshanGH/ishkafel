import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../log/app_log.dart';
import 'analysis_pipeline.dart';
import 'segmentation_builder.dart';

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
///
/// **更要紧的是不缓存「指向别处文件的路径」**。真机事故（2026-09-04）：
/// 两条任务用同一条源片，先分析的那条把人声轨落在自己名下，路径写进了
/// 这份缓存；那条任务被删后，软件按规矩清光它名下的产物，人声轨跟着走了。
/// 另一条任务再打开时命中缓存，拿回一条指向空地址的路径，界面一直喊
/// 「没有分离出纯人声轨」，而且**怎么重新分析都好不了**——命中缓存直接
/// 返回，压根走不到分离那一步。
///
/// 规矩定死：**任何归属于某条任务的路径都不许进这里**。缓存只装
/// 「按片子稳定、且不依赖任何一条任务活着」的数据（句子、切点）。
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
      // 老缓存里可能还留着人声轨路径，一律不认——理由见 [save]
      return PreparedAnalysis.tryFromJson(jsonDecode(f.readAsStringSync()))
          ?.withoutStems();
    } catch (e) {
      AppLog.warn('分析产物缓存读不动（$sourcePrint）：$e');
      return null;
    }
  }

  File _draftsFor(String print) => File(p.join(_dir.path, '$print.drafts.json'));

  /// 取语义切分草稿。**这才是真正锁住单元数的那一层**：ASR 句子稳定，
  /// 而按语义分组是 LLM 干的——真机上同一条片子切出 3/4/5 个单元，
  /// 差别就在这儿。
  List<UnitDraft>? loadDrafts(String? sourcePrint) {
    if (sourcePrint == null || sourcePrint.isEmpty) return null;
    try {
      final f = _draftsFor(sourcePrint);
      if (!f.existsSync()) return null;
      final raw = jsonDecode(f.readAsStringSync());
      if (raw is! List || raw.isEmpty) return null;
      final out = <UnitDraft>[];
      for (final e in raw) {
        final d = UnitDraft.tryFromJson(e);
        // 一条读不动就整份作废：缺一段的切分比没有更危险
        if (d == null) return null;
        out.add(d);
      }
      return out;
    } catch (e) {
      AppLog.warn('切分草稿缓存读不动（$sourcePrint）：$e');
      return null;
    }
  }

  void saveDrafts(String? sourcePrint, List<UnitDraft> drafts) {
    if (sourcePrint == null || sourcePrint.isEmpty || drafts.isEmpty) return;
    try {
      final f = _draftsFor(sourcePrint);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode([for (final d in drafts) d.toJson()]));
    } catch (e) {
      AppLog.warn('切分草稿缓存写不进（$sourcePrint）：$e');
    }
  }

  void save(String? sourcePrint, PreparedAnalysis prepared) {
    if (sourcePrint == null || sourcePrint.isEmpty) return;
    try {
      final f = _fileFor(sourcePrint);
      f.parent.createSync(recursive: true);
      // **人声轨路径不进缓存**：它归任务所有（落在 `stems/<taskId>/`），
      // 任务一删就被清掉；而这份缓存按源文件内容存，能活得比任何一条任务
      // 都久。存进来就会在下一条任务里变成一个指向空地址的路径
      f.writeAsStringSync(jsonEncode(prepared.withoutStems().toJson()));
    } catch (e) {
      // 存不下只是下次要重算，不该让这次导入失败
      AppLog.warn('分析产物缓存写不进（$sourcePrint）：$e');
    }
  }
}
