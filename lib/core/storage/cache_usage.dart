import 'dart:io';

import 'package:path/path.dart' as p;

import '../log/app_log.dart';
import 'task_artifacts.dart';

/// 缓存占用快照（不可变）
class CacheUsage {
  final int coversBytes;
  final int workBytes;
  final int fileCount;

  /// 归属不到任何现存任务的产物（任务已删但文件还在）
  final int orphanBytes;
  final int orphanCount;

  const CacheUsage({
    required this.coversBytes,
    required this.workBytes,
    required this.fileCount,
    required this.orphanBytes,
    required this.orphanCount,
  });

  static const empty = CacheUsage(
      coversBytes: 0, workBytes: 0, fileCount: 0, orphanBytes: 0, orphanCount: 0);

  int get totalBytes => coversBytes + workBytes;

  /// 点「清理」能真正释放的空间。只含孤儿——把在用任务的产物算进来，
  /// 用户清理后现有任务就会失去封面和波形。
  int get reclaimableBytes => orphanBytes;
}

/// 扫描并清理本地缓存。
///
/// 只认「孤儿」为可清理对象，且判定依据是调用方给出的现存任务 id 集合——
/// 服务自己不猜哪条任务还在。**哪些东西算一条任务的产物由
/// [TaskArtifacts] 说了算**，和删任务时清理的是同一份清单；两处一旦分叉，
/// 设置页算出来的可回收空间就会和实际清掉的东西对不上。
class CacheScanner {
  final Directory dataDir;

  CacheScanner({required this.dataDir});

  TaskArtifacts get _artifacts => TaskArtifacts(dataDir);

  Future<CacheUsage> scan({required Set<String> knownTaskIds}) async {
    final artifacts = _artifacts;
    final orphans = artifacts.orphans(knownTaskIds);
    var orphanBytes = 0;
    for (final entity in orphans) {
      orphanBytes += TaskArtifacts.sizeOf(entity);
    }

    return CacheUsage(
      coversBytes: _bytesOf(artifacts.coversDir),
      workBytes: _bytesOf(artifacts.workDir) + _previewBytes(),
      fileCount: _fileCount(artifacts.coversDir) +
          _fileCount(artifacts.workDir) +
          _previewFileCount(),
      orphanBytes: orphanBytes,
      orphanCount: orphans.length,
    );
  }

  /// 删除孤儿产物，返回**实际**释放的字节数（删失败的不计入，不虚报）。
  ///
  /// 物料改成按项目存之后这里简单了一大截：以前预览代理按内容指纹命名、
  /// 判不了归属，只能按 10GB 配额硬砍；人声分离按素材归档，得拿「现存任务
  /// 还引用哪些素材」反推孤儿。现在两者都在任务名下，**删任务直接带走**，
  /// 那两套机制不再需要
  Future<int> purgeOrphans({
    required Set<String> knownTaskIds,
    @Deprecated('物料已按任务存，不再需要反查引用') Set<String>? referencedStems,
  }) async {
    final artifacts = _artifacts;
    return artifacts.delete([
      ...artifacts.orphans(knownTaskIds),
      // 废弃目录一并带走：没人读的数据不该继续占着盘
      ...artifacts.retired(),
    ]);
  }

  int _bytesOf(Directory dir) =>
      dir.existsSync() ? TaskArtifacts.sizeOf(dir) : 0;

  /// 预览/导出/配音那几个按任务分的目录也要算进「工作目录占用」——
  /// 它们才是大头（真机上预览画面切片 275M、预览音轨 88M）
  int _previewBytes() {
    var total = 0;
    for (final name in [
      ...TaskArtifacts.perTaskDirNames,
      ...TaskArtifacts.sharedCacheDirNames,
    ]) {
      total += _bytesOf(Directory(p.join(dataDir.path, name)));
    }
    return total;
  }

  int _previewFileCount() {
    var total = 0;
    for (final name in [
      ...TaskArtifacts.perTaskDirNames,
      ...TaskArtifacts.sharedCacheDirNames,
    ]) {
      total += _fileCount(Directory(p.join(dataDir.path, name)));
    }
    return total;
  }

  static int _fileCount(Directory dir) {
    if (!dir.existsSync()) return 0;
    try {
      return dir
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .length;
    } catch (e) {
      AppLog.warn('统计缓存文件数失败 ${dir.path}：$e');
      return 0;
    }
  }
}

const _kb = 1024;
const _mb = _kb * 1024;
const _gb = _mb * 1024;

/// 容量文案：按量级换单位。GB 保留两位（数字大，一位小数的跳变太粗），
/// MB/KB 一位即可，B 不带小数。
String formatBytes(int bytes) {
  if (bytes >= _gb) return '${(bytes / _gb).toStringAsFixed(2)} GB';
  if (bytes >= _mb) return '${(bytes / _mb).toStringAsFixed(1)} MB';
  if (bytes >= _kb) return '${(bytes / _kb).toStringAsFixed(1)} KB';
  return '$bytes B';
}
