import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../log/app_log.dart';
import 'frame_check.dart';

/// 「这条素材的画面看过没有」的**跨任务**缓存。
///
/// 素材库里的素材会被反复用到——同一个任务的不同单元、不同任务、不同人。
/// **一条素材看一次就够，不是每个任务看一次**：每次都重看是拿钱换一个
/// 已经知道的答案。
///
/// 这份缓存还有一个用处：让 `candidates` 零成本地告诉 Agent「这条以前
/// 看过、画面上烧着字」。此前它只能先提交、等 `apply` 报错再回去重挑——
/// 验收 Agent 的原话是「人挑一次，我挑两次」。
///
/// 按**素材 id** 存而不是按内容指纹：素材本体不一定在本地（挑素材那一刻
/// 常常还没下），而 miaoa 的素材 id 是稳定的。代价是素材库那边换掉同一个
/// id 下的内容时会读到旧结论——所以同帧数的新结果一律覆盖旧的。
class FrameCheckCache {
  final Directory dir;

  /// 「用过」的先后。**不靠文件系统时间戳**：同一秒里写下的一批文件时间
  /// 完全相同，排序就成了随机的，清理时留谁全看运气。这是个进程内的
  /// 单调计数器，只要能排出先后就够——重启后从头数不影响正确性
  /// （最坏是把一批老的当成同样老，那本来就是要删的那批）
  static int _tick = 0;

  /// 最多留几条。一条几百字节，五千条也就几 MB——但盘上的东西必须有上限
  static const int maxEntries = 5000;

  const FrameCheckCache({required this.dir});

  File _fileOf(int materialId) => File(p.join(dir.path, '$materialId.json'));

  /// 看过没有。没看过（或缓存坏了）返回 null——**不是空结果**：
  /// 「没看过」和「看过、画面干净」是两件事
  FrameCheck? get(int materialId) {
    final file = _fileOf(materialId);
    if (!file.existsSync()) return null;
    try {
      final json = jsonDecode(file.readAsStringSync());
      if (json is! Map) return null;
      final burned = json['burnedText'];
      if (burned is! List) return null;
      _touch(materialId, json);
      return FrameCheck(
        burnedText: [
          for (final e in burned)
            if (e is String) e,
        ],
        productBrand:
            json['productBrand'] is String ? json['productBrand'] as String : null,
        framesSeen: json['framesSeen'] is int ? json['framesSeen'] as int : 1,
      );
    } catch (e) {
      AppLog.warn('素材 $materialId 的画面自查缓存读不出来（$e），当作没看过');
      return null;
    }
  }

  /// 碰一下：清理时按最近用过留
  void _touch(int materialId, Map json) {
    try {
      _fileOf(materialId)
          .writeAsStringSync(jsonEncode({...json, 'usedAt': ++_tick}));
    } catch (_) {
      // 记不上不影响读，只是它在清理时排得靠前（更容易被删）
    }
  }

  /// 记下来。**看得更全的结果覆盖看得少的，反过来不覆盖**——
  /// 用一帧的结论顶掉三帧的，等于把看全的退回没看全
  void put(int materialId, FrameCheck check) {
    final existing = get(materialId);
    if (existing != null && existing.framesSeen > check.framesSeen) return;
    try {
      dir.createSync(recursive: true);
      _fileOf(materialId).writeAsStringSync(jsonEncode({
        'burnedText': check.burnedText,
        if (check.productBrand != null) 'productBrand': check.productBrand,
        'framesSeen': check.framesSeen,
        'usedAt': ++_tick,
      }));
    } catch (e) {
      // 存不下不影响这一次的结果，只是下次还得再看一遍
      AppLog.warn('素材 $materialId 的画面自查结果没存下（$e）');
    }
  }

  /// 这份缓存上次被用是第几轮。读不出来算最老的（该删的就是它）
  int _usedAtOf(File f) {
    try {
      final json = jsonDecode(f.readAsStringSync());
      return json is Map && json['usedAt'] is int ? json['usedAt'] as int : -1;
    } catch (_) {
      return -1;
    }
  }

  /// 超出配额时删最久没用过的。盘上躺着的每一份数据都要有人读、有人删
  void prune() {
    if (!dir.existsSync()) return;
    final files = dir.listSync().whereType<File>().toList();
    if (files.length <= maxEntries) return;
    final usedAt = {for (final f in files) f.path: _usedAtOf(f)};
    files.sort((a, b) => usedAt[a.path]!.compareTo(usedAt[b.path]!));
    for (final f in files.take(files.length - maxEntries)) {
      try {
        f.deleteSync();
      } catch (_) {
        // 删不掉不是错误，下次再说
      }
    }
  }
}
