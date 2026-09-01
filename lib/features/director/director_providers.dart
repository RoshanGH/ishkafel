import '../settings/settings_providers.dart';
import '../../core/miaoa/query_frame_uploader.dart';
import '../../core/miaoa/miaoa_gateway.dart';
import 'package:path/path.dart' as p;

import 'package:file_selector/file_selector.dart';

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/script/shot_frame_check.dart';

import '../../core/ai/taggers.dart';
import '../../core/miaoa/candidate_probe.dart';
import '../../core/miaoa/miaoa_content_service.dart';
import '../../core/miaoa/miaoa_tag_service.dart';
import '../../core/script/line_tagger.dart';
import '../../core/script/script_service_wiring.dart';
export '../../core/script/script_service_wiring.dart' show buildRefShotTagger;
import '../../core/script/script_transcriber.dart';

/// 「从视频提取脚本」的服务。null = AI 凭据不全——编导台把入口禁用并
/// 说明原因，绝不让用户点了之后撞网络错误。真实实例在 main.dart 注入
/// （见 service_wiring.buildScriptTranscriber）。
final scriptTranscriberProvider = Provider<ScriptTranscriber?>((ref) => null);

/// 行台词打标（复用 U 层打标管线）。null = 方舟凭据缺失，
/// 「自动打标」禁用并说明原因。真实实例在 main.dart 注入
final lineTaggerProvider = Provider<LineTagger?>((ref) => null);

/// 参考素材选择器：视频或图片都收（手动传参考时用）。
/// 单测 override 成假实现，不弹真实系统文件框
typedef RefFilePicker = Future<String?> Function();

final refFilePickerProvider = Provider<RefFilePicker>((ref) => pickRefFile);

Future<String?> pickRefFile() async {
  const video = XTypeGroup(label: '参考视频', extensions: ['mp4', 'mov']);
  const image =
      XTypeGroup(label: '参考图', extensions: ['jpg', 'jpeg', 'png', 'webp']);
  final file = await openFile(acceptedTypeGroups: const [video, image]);
  return file?.path;
}

/// 参考视觉镜头打标（多帧 vision，一次给标签 + 画面描述——与 U 层
/// 视觉镜头打标同一个 ShotTagger）。null = 方舟凭据缺失
final refShotTaggerProvider = Provider<ShotTagger?>((ref) => null);

/// 「画面相似」用的查询帧上传器。
///
/// 妙啊的以图搜视频只吃 OSS key，而参考镜的首帧只在本地（打标时抽的），
/// 所以要先传上去。传到一个专门放查询帧的二级文件夹里，别混进正经素材；
/// 按内容指纹记着，同一张不重复传。
///
/// null = 还没有数据目录（缓存索引没地方放）
final queryFrameUploaderProvider = Provider<QueryFrameUploader?>((ref) {
  final dataDir = ref.watch(dataDirProvider);
  if (dataDir == null) return null;
  return QueryFrameUploader(
    gateway: MiaoaGateway(),
    folderId: queryFrameFolderId,
    cacheDir: Directory(p.join(dataDir.path, 'query_frames')),
  );
});

/// 查询帧落在哪个二级文件夹。
///
/// 这些图只是搜索用的中间物，单独放一处——混进正经素材里，
/// 别人搜素材时会翻到一堆莫名其妙的截图
const queryFrameFolderId = 2689;

/// 找镜头面板的三件套：内容检索、规格探测、标签体系。
/// 默认真实实例（构造不起子进程，真正调用才 exec）；单测 override
final shotSearchServicesProvider = Provider<ShotSearchServices>(
    (ref) => ShotSearchServices(
          content: MiaoaContentService(),
          probe: CandidateProbe(),
          tags: MiaoaTagService(),
        ));

class ShotSearchServices {
  final MiaoaContentService content;
  final CandidateProbe probe;
  final MiaoaTagService tags;

  const ShotSearchServices(
      {required this.content, required this.probe, required this.tags});
}

/// 素材画面自查（烧字 + 产品露出品牌）的装配。
///
/// 为 null 表示这台机器上没接（方舟凭据缺失或测试环境）——那时镜头记成
/// 「未检查」，**绝不冒充「画面没问题」**。装配逻辑在 core
/// （`frame_check_wiring.dart`），命令行那头共用同一份。
final shotFrameCheckFactoryProvider =
    Provider<ShotFrameCheck? Function(Directory dataDir, String taskId)?>(
        (ref) => null);

/// 按任务造「生成配音」服务。null = 语音凭据不全，配音节禁用并说明原因。
/// 装配逻辑在 core（`script_service_wiring.dart`），CLI 与界面共用同一份
final lineVoiceFactoryProvider = Provider<LineVoiceFactory?>((ref) => null);

/// 按任务造「听参考片这一句怎么念」的分析服务。null = 方舟凭据不全，
/// 配音会退回默认语气（**这件事要说给用户听**，见 `_generateVoiceCore`）。
/// 同样装配在 core，CLI 与界面共用一份
final lineDeliveryFactoryProvider =
    Provider<LineDeliveryFactory?>((ref) => null);
