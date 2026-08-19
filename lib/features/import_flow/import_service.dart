import 'dart:io';
import 'package:path/path.dart' as p;

import '../../core/editing/blank_unit_ops.dart';
import '../../core/models/semantic_unit.dart';
import '../../core/ffmpeg/ffprobe_service.dart';
import '../../core/ffmpeg/process_runner.dart';
import '../../core/ffmpeg/thumbnail_service.dart';
import '../../core/log/app_log.dart';
import '../../core/models/renew_task.dart';
import '../../core/script/script_doc.dart';
import '../../core/models/tag_group_ref.dart';
import '../../core/models/project_ref.dart';
import '../../core/models/video_info.dart';
import '../../core/storage/task_repository.dart';
import '../../core/storage/task_seq.dart';
import 'import_exception.dart';

/// 导入编排：探测元信息 → 创建任务 → 抽封面 → 落库
class ImportService {
  final TaskRepository repository;
  final FfprobeService ffprobe;
  final ThumbnailService thumbnails;
  final Directory coversDir;
  final String Function() idGenerator;
  final DateTime Function() clock;

  ImportService({
    required this.repository,
    required this.ffprobe,
    required this.thumbnails,
    required this.coversDir,
    String Function()? idGenerator,
    DateTime Function()? clock,
  })  : idGenerator = idGenerator ?? _defaultId,
        clock = clock ?? DateTime.now;

  static String _defaultId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  /// 建一条**空白任务**：没有原片，分子手动加、标签手动填，只靠标签检索
  /// 素材拼片。
  ///
  /// 跟导入的差别只有「没有原片」这一件事：不探规格、不抽封面、不排分析，
  /// 建出来直接是 ready。标签组照旧——那是「上哪儿找素材、按什么打标」，
  /// 跟有没有原片无关。
  /// 脚本成片任务：以脚本行为根（「脚本即成片」），工作页是编导台。
  /// 建出来自带一个空行，编导打开就能写
  Future<RenewTask> createScript({
    required String name,
    List<TagGroupRef> unitTagGroups = const [],
    List<TagGroupRef> shotTagGroups = const [],
    String unitTagPrompt = '',
    String shotTagPrompt = '',
    ProjectRef? project,
  }) async {
    final now = clock();
    final task = RenewTask(
      id: idGenerator(),
      seq: await nextTaskSeq(repository),
      name: name.trim().isEmpty ? '未命名脚本' : name.trim(),
      sourcePath: null,
      script: ScriptDoc.empty(),
      status: RenewTaskStatus.ready,
      createdAt: now,
      updatedAt: now,
      unitTagGroups: unitTagGroups,
      shotTagGroups: shotTagGroups,
      unitTagPrompt: unitTagPrompt,
      shotTagPrompt: shotTagPrompt,
      project: project,
    );
    await repository.save(task);
    return task;
  }

  Future<RenewTask> createBlank({
    required String name,
    List<TagGroupRef> unitTagGroups = const [],
    List<TagGroupRef> shotTagGroups = const [],
    String unitTagPrompt = '',
    String shotTagPrompt = '',
    ProjectRef? project,
  }) async {
    final now = clock();
    final task = RenewTask(
      id: idGenerator(),
      seq: await nextTaskSeq(repository),
      name: name.trim().isEmpty ? '未命名拼片' : name.trim(),
      // 没有原片。用 null 而不是空串：空串是个谎，且不会有任何地方报错
      sourcePath: null,
      // 建出来就给 [blankInitialUnits] 个空分子：进去是一片空白的话，
      // 用户第一件事是找「怎么开始」；有几个空位摆着，直接就能点着填
      units: _initialBlankUnits(),
      status: RenewTaskStatus.ready,
      createdAt: now,
      updatedAt: now,
      unitTagGroups: unitTagGroups,
      shotTagGroups: shotTagGroups,
      unitTagPrompt: unitTagPrompt,
      shotTagPrompt: shotTagPrompt,
      project: project,
    );
    await repository.save(task);
    return task;
  }

  /// 新建空白任务时先摆几个空分子
  static const blankInitialUnits = 4;

  static List<SemanticUnit> _initialBlankUnits() {
    var units = <SemanticUnit>[];
    for (var i = 0; i < blankInitialUnits; i++) {
      units = BlankUnitOps.append(units);
    }
    return units;
  }

  /// [unitTagGroups] / [shotTagGroups] 来自新建任务向导；为空表示该层
  /// 不打标（无受控词表可用）。[unitTagPrompt] / [shotTagPrompt] 是两层各自
  /// 的打标约束（一层一条）。
  Future<RenewTask> importLocalFile(
    String filePath, {
    List<TagGroupRef> unitTagGroups = const [],
    List<TagGroupRef> shotTagGroups = const [],
    String unitTagPrompt = '',
    String shotTagPrompt = '',
    ProjectRef? project,
  }) async {
    final info = await _probe(filePath);
    final id = idGenerator();
    final now = clock();
    await coversDir.create(recursive: true);
    final coverPath = p.join(coversDir.path, '$id.jpg');
    await thumbnails.extractCover(videoPath: filePath, outPath: coverPath);
    final task = RenewTask(
      id: id,
      seq: await nextTaskSeq(repository),
      name: p.basenameWithoutExtension(filePath),
      sourcePath: filePath,
      videoInfo: info,
      coverPath: coverPath,
      status: RenewTaskStatus.analyzing,
      createdAt: now,
      updatedAt: now,
      unitTagGroups: unitTagGroups,
      shotTagGroups: shotTagGroups,
      unitTagPrompt: unitTagPrompt,
      shotTagPrompt: shotTagPrompt,
      project: project,
    );
    await repository.save(task);
    return task;
  }

  /// 元信息探测 + 边界校验：任何异常都翻译成面向用户的中文提示，
  /// 校验不通过时在这里就拒绝导入（不建任务、不抽封面、不落库），
  /// 避免非法帧率的素材流到审片台后按帧计算崩溃。
  Future<VideoInfo> _probe(String filePath) async {
    final VideoInfo info;
    try {
      info = await ffprobe.probe(filePath);
    } on MediaToolMissingException catch (e) {
      // 组件缺失的提示本身就是安装引导，原样透传
      throw ImportException(e.message, cause: e);
    } on FormatException catch (e) {
      AppLog.warn('导入被拒绝（元信息不完整）$filePath：$e');
      throw ImportException(_incompleteMetadataMessage, cause: e);
    } catch (e) {
      AppLog.warn('导入被拒绝（读取视频信息失败）$filePath：$e');
      throw ImportException(_unreadableMessage, cause: e);
    }
    if (info.fps <= 0 || !info.fps.isFinite) {
      AppLog.warn('导入被拒绝（帧率非法 ${info.fps}）$filePath');
      throw const ImportException(_incompleteMetadataMessage);
    }
    return info;
  }

  static const _incompleteMetadataMessage =
      '这个视频缺少可用的帧率信息，无法按帧精确切分，暂不支持导入。'
      '可先用其他工具转码（例如导出为 30fps 的 MP4）后再试。';

  static const _unreadableMessage = '无法读取这个视频的信息，请确认文件完整且为 MP4 / MOV 格式。';
}
