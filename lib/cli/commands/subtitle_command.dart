import 'dart:io';

import '../../core/models/renew_task.dart';
import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_log.dart';
import '../../core/storage/task_mutation.dart';
import '../../core/storage/task_seq.dart';
import '../../core/subtitle/subtitle_style.dart';
import '../../core/storage/agent_presence.dart';
import '../agent_stage.dart';
import '../cli_output.dart';
import '../subtitle_view.dart';

/// `ishkafel subtitle check|show <任务>` / `ishkafel subtitle <任务> [--preset …]`
///
/// 三条路都挂在同一个命令名下：
/// - `check` / `show` 是**只读**的字幕报告入口（Task 6 的 `subtitleReport` /
///   `subtitleShotReport`），不建 `AgentStage`、不写在场状态——看一眼不算
///   「在动这条任务」。
/// - 不给子命令时是**老用法**（样式旋钮），原样保留：真会改数据（落
///   `TaskMutation`），也就该有在场状态。
///
/// 分流只看 `rest.first` 是不是字面量 `check`/`show`——任务 id 恰好叫这两个
/// 词的话会被误判走新路。跟 `voice generate <任务>` 挡在 `voice <任务>`
/// 前面是同一个既有约定：任务 id 是内部生成的不透明字符串，不会真撞上
/// 关键字，这里不额外加判定，省得为一个几乎不会发生的情况多一条分支
/// 没人测得到。
Future<int> runSubtitleCommand({
  required List<String> rest,
  required Directory dataDir,

  /// 可视模式：字幕样式改完，界面上当场能看见新样子
  bool? visual,
  String? holder,
  String? preset,
  String? bottomRatio,
  String? fontRatio,
  String? colorHex,

  /// `show` 用：两个都给才出单镜详情，否则出全片报告
  int? unitIndex,
  int? shotIndex,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln(_usage);
    return exitBadUsage;
  }

  if (rest.first == 'check' || rest.first == 'show') {
    return _runReadOnly(
      sub: rest.first,
      rest: rest,
      dataDir: dataDir,
      unitIndex: unitIndex,
      shotIndex: shotIndex,
      out: out,
      err: sink,
    );
  }

  return _runStyle(
    rest: rest,
    dataDir: dataDir,
    visual: visual,
    holder: holder,
    preset: preset,
    bottomRatio: bottomRatio,
    fontRatio: fontRatio,
    colorHex: colorHex,
    out: out,
    err: sink,
  );
}

const String _usage = '用法：\n'
    '  ishkafel subtitle check <任务 id>                字幕自查：哪几镜有毛病、为什么\n'
    '  ishkafel subtitle show  <任务 id> [--unit i --shot j]   字幕报告：全片或单镜\n'
    '  ishkafel subtitle <任务 id> '
    '[--preset whiteOutline|whiteBox|yellowOutline|blurBox] '
    '[--bottom 0.22] [--font 0.034] [--color RRGGBB]        字幕样式';

/// `check` / `show` 共用的入口：只读，找不到任务就直说，不碰任何任务数据。
Future<int> _runReadOnly({
  required String sub,
  required List<String> rest,
  required Directory dataDir,
  int? unitIndex,
  int? shotIndex,
  StringSink? out,
  required StringSink err,
}) async {
  if (rest.length < 2) {
    err.writeln(_usage);
    return exitBadUsage;
  }
  final repository = FileTaskRepository(dataDir);
  final task = await resolveTaskRef(repository, rest[1]);
  if (task == null) {
    err.writeln('没有这个任务：${rest[1]}');
    return exitNotFound;
  }

  if (sub == 'check') {
    emitJson(_checkReport(task, dataDir: dataDir), out: out);
    return 0;
  }

  // show：--unit --shot 两个都给了才是单镜详情，否则是全片报告
  if (unitIndex != null && shotIndex != null) {
    final detail = subtitleShotReport(
      task,
      unitIndex: unitIndex,
      shotIndex: shotIndex,
      dataDir: dataDir,
    );
    if (detail == null) {
      // null 只表示下标不存在——跟「算不准」（framesUnavailable）是两回事，
      // 见 subtitle_view.dart 里 subtitleShotReport 上那段注释
      err.writeln('这一镜不存在：U${unitIndex + 1}S${shotIndex + 1}');
      return exitNotFound;
    }
    emitJson(detail, out: out);
    return 0;
  }

  emitJson(subtitleReport(task, dataDir: dataDir), out: out);
  return 0;
}

/// `check` 只出问题清单，不出别的——它是入口，不是报告，给了细节就没人看了。
///
/// `framesUnavailable` 原样透出去：那是一条带补救命令的实话，不是错误，
/// 也不能吞掉（见 subtitle_view.dart 里 `_framesUnavailableNote`）。
///
/// 问题的「为什么」（note）从 `subtitleShotReport` 再取一遍，不在这里自己
/// 拼文案——`subtitleReport` 的 shot 行只给 `kind`（逐镜扫一遍够用），
/// `subtitleShotReport` 才带 `note`。两份报告的问题描述只认一个源头，
/// 不会走岔
Map<String, dynamic> _checkReport(RenewTask task, {required Directory dataDir}) {
  final report = subtitleReport(task, dataDir: dataDir);
  if (report.containsKey('framesUnavailable')) return report;

  final shots = (report['shots'] as List).cast<Map<String, dynamic>>();
  final problems = <Map<String, dynamic>>[];
  for (final row in shots) {
    final kinds = row['problems'] as List?;
    if (kinds == null || kinds.isEmpty) continue;
    final at = row['at'] as String;
    final detail = subtitleShotReport(
      task,
      unitIndex: row['unit'] as int,
      shotIndex: row['shot'] as int,
      dataDir: dataDir,
    );
    final detailProblems = detail?['problems'] as List?;
    if (detailProblems != null) {
      for (final p in detailProblems.cast<Map<String, dynamic>>()) {
        problems.add({'at': at, 'kind': p['kind'], 'note': p['note']});
      }
    } else {
      // 拿不到 note 就退回只报 kind——理论上不该发生（全片报告都成功了，
      // 同一个下标的单镜报告没道理算不出来），但宁可少报一句 note，
      // 不能因为这一步的意外让整条 check 交白卷
      for (final k in kinds) {
        problems.add({'at': at, 'kind': k});
      }
    }
  }
  return {'taskId': task.id, 'problems': problems};
}

/// 老用法：字幕样式旋钮（位置、字号、预设、字色）。**主要用途是遮挡素材
/// 自带的烧录字幕。** 素材库里不少分镜画面里本来就烧着别家品牌的字，而
/// 画面描述里一个字都看不出来——真机上撞过：描述写「成人给小孩按摩额头」，
/// 画面底部烧着「冰冰凉凉的好舒服呀」。默认的白字黑描边盖不住它，成片上
/// 两行字打架，片子直接废。
///
/// 不给参数就报现状。
Future<int> _runStyle({
  required List<String> rest,
  required Directory dataDir,
  bool? visual,
  String? holder,
  String? preset,
  String? bottomRatio,
  String? fontRatio,
  String? colorHex,
  StringSink? out,
  required StringSink err,
}) async {
  final repository = FileTaskRepository(dataDir);
  final task = await resolveTaskRef(repository, rest.first);
  if (task == null) {
    err.writeln('没有这个任务：${rest.first}');
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
      err.writeln('认不出这个预设：$preset。只有这四个：'
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
      err.writeln('--bottom 要 0~1 之间的小数（字幕基线距画面底部的比例，'
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
      err.writeln('--font 要 0~1 之间的小数（字号占画面高度的比例，'
          '0.034 在 1920 高下约 65px）');
      return exitBadUsage;
    }
    parsedFontRatio = v;
    changed = true;
  }

  String? parsedColorHex;
  if (colorHex != null) {
    final v = colorHex.trim();
    if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(v)) {
      // 编导台在这条路上给的是六色选择，CLI 只认同一种格式——不猜、
      // 不做别的解析（比如 #RRGGBB 或颜色名），认不出就当场说清
      err.writeln('认不出这个颜色：$colorHex。要六位十六进制色值，'
          '不带 #（比如 33D6A6）');
      return exitBadUsage;
    }
    parsedColorHex = v.toUpperCase();
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
        var applied = fresh.subtitle.copyWith(
          preset: parsedPreset,
          bottomRatio: parsedBottomRatio,
          fontRatio: parsedFontRatio,
        );
        // colorHex 走独立的一次 copyWith：SubtitleStyle.copyWith 用哨兵值
        // 区分「没给」和「给了 null（清掉自定义色）」，这里没让 CLI 支持
        // 清色（那是第二批的事），所以只在真给了值的时候才碰这个字段——
        // 一起传会把「没给」误当「清掉」，把人没提的颜色悄悄清空
        if (parsedColorHex != null) {
          applied = applied.copyWith(colorHex: parsedColorHex);
        }
        return TaskEdit(
          task: fresh.copyWith(subtitle: applied),
          before: {
            'preset': before.preset.name,
            'bottomRatio': before.bottomRatio,
            'fontRatio': before.fontRatio,
            'colorHex': before.colorHex,
          },
          after: {
            'preset': applied.preset.name,
            'bottomRatio': applied.bottomRatio,
            'fontRatio': applied.fontRatio,
            'colorHex': applied.colorHex,
          },
        );
      },
    );
    stage.end();
    if (updated == null) {
      // 没改成就不能把改之前的旧样式当结果打印出去、还退出码 0——
      // 那是命令行在撒谎：说改了，其实盘上什么都没变
      err.writeln('这条任务在写入字幕样式的过程中被删掉了：${task.id}');
      return exitNotFound;
    }
    style = updated.subtitle;
  }

  emitJson({
    'taskId': task.id,
    'preset': style.preset.name,
    'bottomRatio': style.bottomRatio,
    'fontRatio': style.fontRatio,
    if (style.colorHex != null) 'colorHex': style.colorHex,
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
