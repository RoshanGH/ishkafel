import 'dart:io';

import '../core/ai/frame_check_wiring.dart';
import '../core/script/shot_frame_check.dart';
import 'commands/analyze_command.dart' show loadCliCredentials;

/// 命令行这头的画面自查：凭据从 `.secrets/` 读（打包时拷进 app 包）。
///
/// 装配逻辑本身在 core（[buildShotFrameCheck]），界面那头共用同一份——
/// **两边各写一份的话迟早只有一份是对的**，而且界面不该反过来引命令行的代码。
ShotFrameCheck? defaultShotFrameCheck({
  required Directory dataDir,
  required String taskId,
}) =>
    buildShotFrameCheck(
      arkApiKey: loadCliCredentials(dataDir).arkApiKey,
      dataDir: dataDir,
      taskId: taskId,
    );
