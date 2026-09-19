import 'dart:io';

import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_log.dart';
import '../../core/storage/task_mutation.dart';
import '../../core/storage/task_seq.dart';
import '../../core/subtitle/subtitle_style.dart';
import '../../core/storage/agent_presence.dart';
import '../agent_stage.dart';
import '../cli_output.dart';

/// `ishkafel subtitle <任务> [--preset blurBox] [--bottom 0.22] [--font 0.034]`
///
/// **主要用途是遮挡素材自带的烧录字幕。** 素材库里不少分镜画面里本来就烧着
/// 别家品牌的字，而画面描述里一个字都看不出来——真机上撞过：描述写
/// 「成人给小孩按摩额头」，画面底部烧着「冰冰凉凉的好舒服呀」。默认的白字
/// 黑描边盖不住它，成片上两行字打架，片子直接废。
///
/// 不给参数就报现状。
Future<int> runSubtitleCommand({
  required List<String> rest,
  required Directory dataDir,

  /// 可视模式：字幕样式改完，界面上当场能看见新样子
  bool? visual,
  String? holder,
  String? preset,
  String? bottomRatio,
  String? fontRatio,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('用法：ishkafel subtitle <任务 id> '
        '[--preset whiteOutline|whiteBox|yellowOutline|blurBox] '
        '[--bottom 0.22] [--font 0.034]');
    return exitBadUsage;
  }
  final repository = FileTaskRepository(dataDir);
  final task = await resolveTaskRef(repository, rest.first);
  if (task == null) {
    sink.writeln('没有这个任务：${rest.first}');
    return exitNotFound;
  }

  // 只校验参数格式、解析成目标值，不在这里改 style——style 的落点必须是
  // TaskMutation.apply 里的 fresh.subtitle，不是这份可能已经过期的 task.subtitle
  SubtitlePreset? parsedPreset;
  var changed = false;

  if (preset != null) {
    final found = SubtitlePreset.values
        .where((p) => p.name.toLowerCase() == preset.trim().toLowerCase())
        .firstOrNull;
    if (found == null) {
      // 只说「无效」等于让人自己猜。四个名字就四个，直接列出来
      sink.writeln('认不出这个预设：$preset。只有这四个：'
          '${SubtitlePreset.values.map((p) => p.name).join(' / ')}');
      return exitBadUsage;
    }
    parsedPreset = found;
    changed = true;
  }

  double? parsedBottomRatio;
  if (bottomRatio != null) {
    final v = double.tryParse(bottomRatio.trim());
    if (v == null || v <= 0 || v >= 1) {
      sink.writeln('--bottom 要 0~1 之间的小数（字幕基线距画面底部的比例，'
          '0.22 大约是竖屏底部安全区上沿）');
      return exitBadUsage;
    }
    parsedBottomRatio = v;
    changed = true;
  }

  double? parsedFontRatio;
  if (fontRatio != null) {
    final v = double.tryParse(fontRatio.trim());
    if (v == null || v <= 0 || v >= 1) {
      sink.writeln('--font 要 0~1 之间的小数（字号占画面高度的比例，'
          '0.034 在 1920 高下约 65px）');
      return exitBadUsage;
    }
    parsedFontRatio = v;
    changed = true;
  }

  var style = task.subtitle;
  if (changed) {
    // 字幕样式是**进成片**的东西（主要拿来遮素材自带的烧字），
    // 人得当场看见改成什么样了
    final stage = AgentStage(
      mode: AgentStageMode.from(visual: visual),
      dataDir: dataDir,
      taskId: task.id,
      holder: holder ?? 'Agent',
    );
    await stage.begin('正在改字幕样式（${parsedPreset?.name ?? style.preset.name}）',
        focus: const AgentFocus(module: 'director'));

    final before = style;
    final updated = await TaskMutation(
      repo: repository,
      dataDir: dataDir,
      by: ActorKind.agent,
      actor: 'Agent',
    ).apply(
      taskId: task.id,
      op: 'subtitle.set',
      edit: (fresh) {
        final applied = fresh.subtitle.copyWith(
          preset: parsedPreset,
          bottomRatio: parsedBottomRatio,
          fontRatio: parsedFontRatio,
        );
        return TaskEdit(
          task: fresh.copyWith(subtitle: applied),
          before: {
            'preset': before.preset.name,
            'bottomRatio': before.bottomRatio,
            'fontRatio': before.fontRatio,
          },
          after: {
            'preset': applied.preset.name,
            'bottomRatio': applied.bottomRatio,
            'fontRatio': applied.fontRatio,
          },
        );
      },
    );
    stage.end();
    if (updated == null) {
      // 没改成就不能把改之前的旧样式当结果打印出去、还退出码 0——
      // 那是命令行在撒谎：说改了，其实盘上什么都没变
      sink.writeln('这条任务在写入字幕样式的过程中被删掉了：${task.id}');
      return exitNotFound;
    }
    style = updated.subtitle;
  }

  emitJson({
    'taskId': task.id,
    'preset': style.preset.name,
    'bottomRatio': style.bottomRatio,
    'fontRatio': style.fontRatio,
    'presets': [
      for (final p in SubtitlePreset.values) p.name,
    ],
    'note': '素材画面里自带烧录字幕时，whiteOutline（白字黑描边）盖不住它——'
        '原字幕会从描边缝里透出来，成片上两行字打架。'
        'whiteBox（半透明黑底条）和 blurBox（毛玻璃）能盖住。'
        '但底条的宽窄是按新字幕的文本框算的：原字幕比新字幕长、'
        '或者位置更高时仍然盖不全，那种素材只能换掉',
  }, out: out);
  return 0;
}
