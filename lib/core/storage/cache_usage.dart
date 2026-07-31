import 'dart:io';

import 'package:path/path.dart' as p;

import '../log/app_log.dart';

/// 中间产物归属判定：文件名等于 id，或以 `id.` / `id_` 开头。
///
/// 不能用裸前缀匹配——id 为 `ab` 时 `abc.pcm` 也会被判成它的产物，清理时
/// 就会误删另一条任务的文件。分隔符是这条判定的全部意义所在。
bool artifactBelongsTo(String fileName, String taskId) =>
    fileName == taskId ||
    fileName.startsWith('$taskId.') ||
    fileName.startsWith('${taskId}_');

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

/// 单个文件的删除动作（注入点：测试可模拟「删不掉」）
typedef FileDeleter = Future<void> Function(File file);

Future<void> _systemDelete(File file) => file.delete();

/// 扫描并清理本地缓存目录。
///
/// 只认「孤儿」为可清理对象，且判定依据是调用方给出的现存任务 id 集合——
/// 服务自己不猜哪条任务还在。
class CacheScanner {
  final Directory coversDir;
  final Directory workDir;
  final FileDeleter deleteFile;

  const CacheScanner({
    required this.coversDir,
    required this.workDir,
    this.deleteFile = _systemDelete,
  });

  Future<CacheUsage> scan({required Set<String> knownTaskIds}) async {
    var coversBytes = 0;
    var workBytes = 0;
    var fileCount = 0;
    var orphanBytes = 0;
    var orphanCount = 0;

    for (final (dir, isCovers) in [(coversDir, true), (workDir, false)]) {
      await for (final entry in _walk(dir)) {
        fileCount++;
        if (isCovers) {
          coversBytes += entry.bytes;
        } else {
          workBytes += entry.bytes;
        }
        if (_isOrphan(entry.name, knownTaskIds)) {
          orphanBytes += entry.bytes;
          orphanCount++;
        }
      }
    }

    return CacheUsage(
      coversBytes: coversBytes,
      workBytes: workBytes,
      fileCount: fileCount,
      orphanBytes: orphanBytes,
      orphanCount: orphanCount,
    );
  }

  /// 删除孤儿产物，返回**实际**释放的字节数（删失败的不计入，不虚报）
  Future<int> purgeOrphans({required Set<String> knownTaskIds}) async {
    var freed = 0;
    for (final dir in [coversDir, workDir]) {
      await for (final entry in _walk(dir)) {
        if (!_isOrphan(entry.name, knownTaskIds)) continue;
        try {
          await deleteFile(entry.file);
          freed += entry.bytes;
        } catch (e) {
          // 单个文件被占用/无权限不该中断整轮清理
          AppLog.warn('清理缓存失败 ${entry.file.path}：$e');
        }
      }
    }
    return freed;
  }

  static bool _isOrphan(String fileName, Set<String> knownTaskIds) =>
      !knownTaskIds.any((id) => artifactBelongsTo(fileName, id));

  /// 递归遍历。只数第一层会把「已清理干净」的假象报给用户。
  Stream<_Entry> _walk(Directory dir) async* {
    if (!await dir.exists()) return;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      try {
        yield _Entry(entity, await entity.length());
      } catch (e) {
        // 扫描期间文件被删掉是正常竞态，跳过即可
        AppLog.warn('读取缓存文件大小失败 ${entity.path}：$e');
      }
    }
  }
}

class _Entry {
  final File file;
  final int bytes;

  _Entry(this.file, this.bytes);

  String get name => p.basename(file.path);
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
