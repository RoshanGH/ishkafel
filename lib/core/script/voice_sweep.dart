import 'dart:io';

import 'package:path/path.dart' as p;

import '../log/app_log.dart';
import 'script_doc.dart';

/// 收掉这个任务里**不再被任何一行引用**的配音文件，返回删掉几个。
///
/// 换一次音色就多一批死 mp3：新配音换上去，旧文件还躺在
/// `voices/<taskId>/` 里。`TaskArtifacts.orphans` 只管「归属不到现存任务」
/// 的整个目录——任务还活着时它一个都不碰，所以这批文件谁都不管。
/// 批量换 28 句音色就是 28 个死文件。
///
/// **不能在编辑过程中调**：撤销栈里的旧版本还指着那些文件，删了就撤成
/// 死链（真机上出现过整行无声，所以生成新配音时刻意不删旧的）。
/// 只在**进入任务那一刻**扫一次——那时撤销栈必然是空的。
int sweepUnusedVoices({
  required Directory dataDir,
  required String taskId,
  required ScriptDoc doc,
}) {
  final dir = Directory(p.join(dataDir.path, 'voices', taskId));
  if (!dir.existsSync()) return 0;
  final used = {
    for (final line in doc.lines)
      if (line.voiceover != null) p.normalize(line.voiceover!.audioPath),
  };
  var removed = 0;
  try {
    // 只收自己认识的那一层文件：子目录留给别的机制管，
    // 免得这里越界删掉不该删的
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      if (used.contains(p.normalize(entity.path))) continue;
      try {
        entity.deleteSync();
        removed++;
      } catch (e) {
        AppLog.warn('无主配音删除失败（${entity.path}）：$e');
      }
    }
  } catch (e) {
    AppLog.warn('配音目录扫描失败（$taskId）：$e');
  }
  return removed;
}
