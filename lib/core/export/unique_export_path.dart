/// 导出落点：**同名不覆盖**。
///
/// 同一个项目往往一直导到同一个目录（上次导到哪儿，下次默认还是那儿），
/// 而文件名只由方案名决定、没有方案名时就是「变体N」——第二批导出的
/// 文件名和上一批一模一样。ffmpeg 一律带 `-y`，撞上就直接盖掉：换了一批
/// 素材重导，上一批成片凭空消失，用户不会收到任何提示（真机踩到）。
///
/// 成片是要交付给客户的东西，「数据不能凭空消失」这条在这儿最实。
/// 所以撞名就往后排 `变体1(2).mp4`、`变体1(3).mp4`，谁都不许被顶掉。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// 上限。到这个数还在撞就不再一个个试了——不是为了省时间，是为了
/// 别在某种意外情形下（比如目录被别的程序不停塞文件）原地转圈
const int _maxAttempts = 999;

/// 在 [dirPath] 里给 [fileName] 找一个还没被占的落点，返回完整路径。
///
/// 目录不存在也能算（导出前才 create），此时必然不撞。
/// 同名的**目录**也算占位——那个名字写不进文件。
String uniqueExportPath(String dirPath, String fileName) {
  final ext = p.extension(fileName);
  final base = p.basenameWithoutExtension(fileName);
  var candidate = p.join(dirPath, fileName);
  for (var n = 2; _taken(candidate) && n <= _maxAttempts; n++) {
    candidate = p.join(dirPath, '$base($n)$ext');
  }
  // 兜到头还在撞：拿时间戳收场。宁可名字难看，也不能覆盖别人
  if (_taken(candidate)) {
    candidate =
        p.join(dirPath, '$base(${DateTime.now().microsecondsSinceEpoch})$ext');
  }
  return candidate;
}

bool _taken(String path) =>
    File(path).existsSync() || Directory(path).existsSync();
