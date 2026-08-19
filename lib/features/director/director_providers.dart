import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/script/script_transcriber.dart';

/// 「从视频提取脚本」的服务。null = AI 凭据不全——编导台把入口禁用并
/// 说明原因，绝不让用户点了之后撞网络错误。真实实例在 main.dart 注入
/// （见 service_wiring.buildScriptTranscriber）。
final scriptTranscriberProvider = Provider<ScriptTranscriber?>((ref) => null);
