import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// 采样多少：头、中、尾各取这么多字节。
///
/// 不整份读：一条 75 秒的成片就有一百多兆，每次导入都全文哈希会卡住界面。
/// 头中尾三段加上文件长度，足以区分「同一条片子」和「另一条片子」——
/// 视频文件在这三处几乎不可能同时撞上。
const int _sampleBytes = 64 * 1024;

/// 源文件的内容指纹。文件不在就返回 null（**不硬造一个**——
/// 造出来会让两个不同的文件命中同一份缓存）。
///
/// 用途：同一条片子重新导入时复用已有的切分结果。
/// 真机上同一个文件导三次切出 3/4/5 个单元（语义切分是 LLM 干的，
/// 有随机性），于是方案文件不能跨任务复用、「1:1 复刻」也打了折扣。
String? sourcePrintOf(String path) {
  final f = File(path);
  if (!f.existsSync()) return null;
  try {
    final len = f.lengthSync();
    final raf = f.openSync();
    try {
      final chunks = <List<int>>[];
      // 头、中、尾各取一段：只读开头的话，剪掉结尾的片子会被当成同一条
      for (final at in [
        0,
        (len ~/ 2 - _sampleBytes ~/ 2).clamp(0, len),
        (len - _sampleBytes).clamp(0, len),
      ]) {
        raf.setPositionSync(at);
        chunks.add(raf.readSync(_sampleBytes));
      }
      final digest = sha256.convert([
        ...utf8.encode('$len|'),
        for (final c in chunks) ...c,
      ]);
      return digest.toString().substring(0, 32);
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    // 读不动就当没有指纹：宁可重算一次，也不能算错
    return null;
  }
}
