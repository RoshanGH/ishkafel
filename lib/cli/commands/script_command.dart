import 'dart:io';

import '../../core/miaoa/miaoa_content_service.dart';
import '../../core/miaoa/miaoa_tag_service.dart';
import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_seq.dart';
import '../cli_output.dart';
import '../script_shot_context.dart';
import 'script_apply_command.dart';
import 'script_run_command.dart';
import '../script_view.dart';

/// `ishkafel script <子命令> <任务>` —— 脚本成片这条线的只读入口。
///
/// 与成片翻新是同一个任务对象的两个字段（`units` / `script`），所以共用
/// 仓库与输出层，只在这里开一层新的命名空间。
///
/// 子命令：
/// - `show <task> [--line <i>]`：任务全貌 / 单行详情
/// - `shots <task> --line <i>`：这一行的候选镜头与判断依据
/// - `subtitles <task> --line <i>`：这一行的断句材料
Future<int> runScriptCommand({
  required List<String> rest,
  required Directory dataDir,
  int? line,

  /// `apply` 用：结果文件路径
  String? file,

  /// `voice` 用：指定音色
  String? voiceId,

  /// `export` 用：输出目录
  String? outputDir,

  /// 可视模式：把软件拉起来，一步一步演给人看
  bool? visual,

  /// 注入点：测试用假实现，真实环境走 miaoa CLI
  MiaoaContentService? content,
  MiaoaTagService? tags,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('用法：ishkafel script <子命令> …\n'
        '  new <名字>                      建一个脚本任务\n'
        '  extract <任务> <参考视频>        识别台词，生成脚本行\n'
        '  voice <任务> [--line N]         生成配音\n'
        '  show <任务> [--line N]          任务全貌 / 单行详情\n'
        '  shots <任务> --line N           候选镜头与判断依据\n'
        '  subtitles <任务> --line N       断句材料\n'
        '  apply <what> <任务> --file f    回填（shots/subtitles/alloc/bgm/\n'
        '                                  lines/shot-edit/screen-text/\n'
        '                                  baseline/line-voice/mix）\n'
        '  export <任务> [--out 目录]      导出成片\n'
        '  jianying <任务>                 写成剪映草稿，去剪映里精修');
    return exitBadUsage;
  }
  if (rest.length < 2 &&
      !['new'].contains(rest.first)) {
    sink.writeln('要指定任务：ishkafel script ${rest.first} <任务 id>');
    return exitBadUsage;
  }
  final sub = rest[0];
  // 执行类：建任务、提取、配音、导出（这几条不需要先解析任务）
  switch (sub) {
    case 'new':
      return runScriptNewCommand(
          rest: rest.sublist(1), dataDir: dataDir, out: out, err: err);
    case 'extract':
      return runScriptExtractCommand(
          rest: rest.sublist(1), dataDir: dataDir, out: out, err: err);
    case 'voice':
      return runScriptVoiceCommand(
        rest: rest.sublist(1),
        dataDir: dataDir,
        line: line,
        voiceId: voiceId,
        out: out,
        err: err,
      );
    case 'jianying':
      return runScriptJianyingCommand(
        rest: rest.sublist(1),
        dataDir: dataDir,
        visual: visual,
        out: out,
        err: err,
      );
    case 'export':
      return runScriptExportCommand(
        rest: rest.sublist(1),
        dataDir: dataDir,
        outputDir: outputDir,
        out: out,
        err: err,
      );
  }
  // apply 多一层：script apply <what> <task>
  if (sub == 'apply') {
    return runScriptApplyCommand(
      rest: rest.sublist(1),
      dataDir: dataDir,
      file: file,
      visual: visual,
      out: out,
      err: err,
    );
  }
  final id = rest[1];
  final task = await resolveTaskRef(FileTaskRepository(dataDir), id);
  if (task == null) {
    sink.writeln('没有这个任务：$id');
    return exitNotFound;
  }
  final doc = task.script;
  if (doc == null) {
    sink.writeln('「${task.name}」不是脚本成片任务——'
        '成片翻新那条线请用 ishkafel task / candidates');
    return exitBadUsage;
  }

  switch (sub) {
    case 'apply':
      // script apply <what> <task> …：把 apply 之后的参数原样递过去
      return runScriptApplyCommand(
        rest: rest.sublist(1),
        dataDir: dataDir,
        file: file,
        visual: visual,
        out: out,
        err: err,
      );
    case 'show':
      try {
        // --line 给的是**人看的行号**（从 1 起），内部一律 0 起
        emitJson(
            line == null
                ? scriptTaskJson(task)
                : scriptLineJson(doc, line - 1),
            out: out);
        return 0;
      } on ArgumentError catch (e) {
        sink.writeln('${e.message}');
        return exitBadUsage;
      }
    case 'shots':
      if (line == null) {
        sink.writeln('要指定行号：ishkafel script shots <任务> --line <行号>');
        return exitBadUsage;
      }
      try {
        final ctx = scriptShotContext(doc, line - 1);
        // 候选走**与界面完全同一条路**：参考镜打过标就按它的画面描述搜。
        // 绝不退回「拿台词搜画面描述」——那个错配 0.1.45 刚砍掉，
        // 台词是一句话、画面描述是一幅画，不在一个维度上
        final refShots = ctx['reference'] as List;
        final description = refShots.isEmpty
            ? ''
            : '${refShots.first['description']}'.trim();
        if (description.isEmpty) {
          emitJson({...ctx, 'candidates': const []}, out: out);
          return 0;
        }
        final services = content ?? MiaoaContentService();
        final tagIds = await _tagIdsOf(
          tags: (refShots.first['tags'] as List).cast<String>(),
          groups: [...task.shotTagGroups, ...task.unitTagGroups],
          service: tags,
        );
        final page = await services.searchByDescription(
          keyword: description,
          tagIds: tagIds,
          projectIds: [if (task.project != null) task.project!.id],
          pageSize: 20,
        );
        emitJson({
          ...ctx,
          'candidates': [
            for (final m in page.items)
              {
                'materialId': m.id,
                'name': m.name,
                'sceneDescription': m.sceneDescription,
                'voiceover': m.voiceover,
                'tags': m.tags,
                if (m.thumbnailUrl != null) 'thumbnailUrl': m.thumbnailUrl,
                if (m.fileKey != null) 'fileKey': m.fileKey,
              },
          ],
        }, out: out);
        return 0;
      } on ArgumentError catch (e) {
        sink.writeln('${e.message}');
        return exitBadUsage;
      }
    case 'subtitles':
      if (line == null) {
        sink.writeln('要指定行号：ishkafel script subtitles <任务> --line <行号>');
        return exitBadUsage;
      }
      try {
        emitJson(scriptSubtitleMaterial(doc, line - 1), out: out);
        return 0;
      } on ArgumentError catch (e) {
        sink.writeln('${e.message}');
        return exitBadUsage;
      }
    default:
      sink.writeln('不认识的子命令：$sub'
          '（可用：new / extract / voice / export / show / shots / subtitles / apply）');
      return exitBadUsage;
  }
}

/// 参考镜的画面标签 → 标签 id（检索约束）。拉不到就不带约束，不挡路
Future<List<int>> _tagIdsOf({
  required List<String> tags,
  required List<dynamic> groups,
  MiaoaTagService? service,
}) async {
  if (tags.isEmpty) return const [];
  try {
    final svc = service ?? MiaoaTagService();
    final all = await svc.listGroups();
    final wanted = {for (final g in groups) g.id as int};
    final ids = <int>[];
    for (final g in all) {
      if (!wanted.contains(g.id)) continue;
      for (final t in await svc.listTags(g.id)) {
        if (tags.contains(t.name)) ids.add(t.id);
      }
    }
    return ids;
  } catch (_) {
    return const [];
  }
}
