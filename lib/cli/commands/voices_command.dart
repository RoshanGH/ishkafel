import 'dart:io';

import '../../core/audio/voice_catalog.dart';
import '../cli_output.dart';

/// `ishkafel voices` —— 有哪些音色可选。
///
/// 手册里一直写着这条命令，**但它一直不存在**（验收 Agent 撞上了）：
/// 手册说「没定过就先问人要哪个音色，别自己挑」，而它既没法列出选项给人看、
/// 又不许自己挑，于是整条配音链路在纯 CLI 下是死的——挑镜头要用配音时长
/// 算坑位，也跟着走不通。
///
/// **手册写了的命令必须真的有**，这条比多一个功能重要：Agent 照着不存在的
/// 命令走，会以为是环境坏了。
int runVoicesCommand({StringSink? out}) {
  emitJson({
    'voices': [
      for (final v in VoiceCatalog.all)
        {
          'id': v.ref.id,
          'name': v.ref.name,
          'scene': v.scene,
          'language': v.language,
        },
    ],
    'next': '把选定的音色定成本片基调：'
        'ishkafel script apply baseline <任务> --file b.json'
        '（内容形如 {"voiceId": "<上面的 id>"}）',
  }, out: out ?? stdout);
  return 0;
}
