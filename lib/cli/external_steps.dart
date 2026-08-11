import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/analysis/analysis_pipeline.dart';
import '../core/analysis/segmentation_builder.dart';
import '../core/analysis/providers.dart';
import '../core/models/semantic_unit.dart';

/// 可以交给调用方去做的 AI 步骤。
///
/// **划线的依据是「输出可不可验证」，不是「调用方有没有这个能力」**
/// （spec 第三节）。一开始设计的是让调用方声明自己会什么，那是错的——
/// 它隐含「调用方的能力和内置 API 等价」这个不成立的前提。
///
/// 真正的问题不是它会不会声明错，而是**有些步骤即使它真有能力，我们也无法
/// 判断它做得对不对**：ASR 的时间戳偏 200ms 就毁掉整条链（切分错位、镜头
/// 对不上、口型飘），而且不会报错，一路静默到看成片才发现。文本本身像模
/// 像样，人眼根本挑不出来。所以 ASR 永远不在这个清单里。
enum ExternalStep {
  /// 把台词切成语义单元。输出可验证：索引连续、不重叠、覆盖全部句子
  segment,

  /// 给单元与镜头贴标签。输出可验证：必须在受控词表内
  tag,
}

ExternalStep? externalStepFrom(String raw) => switch (raw.trim()) {
      'segment' => ExternalStep.segment,
      'tag' || 'tags' => ExternalStep.tag,
      _ => null,
    };

/// 解析 `--external=segment,tag`。认不出的名字返回在 [unknown] 里，
/// 由调用方决定报错——静默忽略会让人以为外包生效了，其实还在烧内置 API
({Set<ExternalStep> steps, List<String> unknown}) parseExternal(String? raw) {
  final steps = <ExternalStep>{};
  final unknown = <String>[];
  for (final piece in (raw ?? '').split(',')) {
    final trimmed = piece.trim();
    if (trimmed.isEmpty) continue;
    final step = externalStepFrom(trimmed);
    if (step == null) {
      unknown.add(trimmed);
    } else {
      steps.add(step);
    }
  }
  return (steps: steps, unknown: unknown);
}

/// 分析中途的落盘状态：前半程的产物 + 还欠哪一步。
///
/// 存在盘上而不是内存里，因为**两次命令之间进程是断的**——`analyze` 停下来
/// 输出 todo，调用方处理完再跑 `apply`，那是另一个进程。
class AnalysisState {
  final PreparedAnalysis prepared;

  /// 还欠调用方做的那些
  final Set<ExternalStep> pending;

  const AnalysisState({required this.prepared, required this.pending});

  Map<String, dynamic> toJson() => {
        'prepared': prepared.toJson(),
        'pending': [for (final s in pending) s.name],
      };

  static AnalysisState? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final prepared = PreparedAnalysis.tryFromJson(raw['prepared']);
    if (prepared == null) return null;
    return AnalysisState(
      prepared: prepared,
      pending: {
        for (final s in (raw['pending'] as List? ?? []))
          ?externalStepFrom('$s'),
      },
    );
  }
}

/// 状态文件：`<dataDir>/analysis_state/<taskId>.json`
File analysisStateFile(Directory dataDir, String taskId) =>
    File(p.join(dataDir.path, 'analysis_state', '$taskId.json'));

void saveAnalysisState(Directory dataDir, String taskId, AnalysisState state) {
  final file = analysisStateFile(dataDir, taskId);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(jsonEncode(state.toJson()));
}

AnalysisState? readAnalysisState(Directory dataDir, String taskId) {
  final file = analysisStateFile(dataDir, taskId);
  if (!file.existsSync()) return null;
  try {
    return AnalysisState.tryFromJson(jsonDecode(file.readAsStringSync()));
  } catch (_) {
    return null;
  }
}

void clearAnalysisState(Directory dataDir, String taskId) {
  final file = analysisStateFile(dataDir, taskId);
  if (file.existsSync()) file.deleteSync();
}

/// 校验并解析调用方回填的**语义切分**。
///
/// **外包出去的是判断，不是数据结构的定义权**：可以说「这几句归一组」，
/// 但不能改句子本身、不能漏掉句子、不能让两个单元重叠。
({List<UnitDraft> drafts, List<String> errors}) parseSegments(
    Object? raw, List<AsrSentence> sentences) {
  if (raw is! Map) return (drafts: const [], errors: ['提交的内容不是一个 JSON 对象']);
  final list = raw['units'];
  if (list is! List || list.isEmpty) {
    return (drafts: const [], errors: ['units 必须是一个非空数组']);
  }

  final errors = <String>[];
  final drafts = <UnitDraft>[];
  var expected = 0;

  for (var i = 0; i < list.length; i++) {
    final where = '第 ${i + 1} 个单元';
    final item = list[i];
    if (item is! Map) {
      errors.add('$where 不是一个对象');
      continue;
    }
    final from = item['fromSentence'];
    final to = item['toSentence'];
    if (from is! int || to is! int) {
      errors.add('$where 要给 fromSentence 与 toSentence（句子下标，含两端）');
      continue;
    }
    if (from != expected) {
      // 不连续意味着有句子被漏掉或者被算了两次——那会让台词与画面错位
      errors.add('$where 应该从第 $expected 句开始，收到的是 $from'
          '（单元必须首尾相接、覆盖全部句子）');
    }
    if (to < from || to >= sentences.length) {
      errors.add('$where 的句子范围 $from~$to 越界（共 ${sentences.length} 句）');
      continue;
    }
    expected = to + 1;
    final picked = sentences.sublist(from, to + 1);
    drafts.add(UnitDraft(
      startMs: picked.first.startMs,
      endMs: picked.last.endMs,
      // 台词由句子拼出来，**不收调用方给的文本**——它可以决定怎么分组，
      // 但不能改台词内容，那是 ASR 的产出
      transcript: picked.map((s) => s.text).join(),
    ));
  }

  if (expected != sentences.length && errors.isEmpty) {
    errors.add('还有 ${sentences.length - expected} 句没有归入任何单元'
        '（从第 $expected 句起）');
  }
  return (drafts: drafts, errors: errors);
}

/// 校验并应用调用方回填的**标签**。
///
/// 标签必须在受控词表内——那是打标的全部意义。词表外的一律拒绝，不做近似
/// 匹配：一个「厨房场景」和「厨房情景」的差别，在检索时就是搜不搜得到。
({List<SemanticUnit> units, List<String> errors}) parseTags(
  Object? raw,
  List<SemanticUnit> units, {
  required Set<String> unitVocabulary,
  required Set<String> shotVocabulary,
}) {
  if (raw is! Map) return (units: units, errors: ['提交的内容不是一个 JSON 对象']);
  final list = raw['units'];
  if (list is! List) return (units: units, errors: ['units 必须是一个数组']);

  final errors = <String>[];
  final byIndex = <int, ({List<String> tags, Map<int, List<String>> shots})>{};

  for (final item in list) {
    if (item is! Map) {
      errors.add('units 里有一项不是对象');
      continue;
    }
    final index = item['unit'];
    if (index is! int || index < 0 || index >= units.length) {
      errors.add('引用了不存在的单元 $index（共 ${units.length} 个）');
      continue;
    }
    final unitTags = _stringList(item['tags']);
    for (final tag in unitTags) {
      if (!unitVocabulary.contains(tag)) {
        errors.add('U${index + 1} 的标签「$tag」不在受控词表里');
      }
    }
    final shotTags = <int, List<String>>{};
    final shots = item['shots'];
    if (shots is Map) {
      for (final entry in shots.entries) {
        final shotIndex = int.tryParse('${entry.key}');
        if (shotIndex == null ||
            shotIndex < 0 ||
            shotIndex >= units[index].shots.length) {
          errors.add('U${index + 1} 引用了不存在的镜头 ${entry.key}');
          continue;
        }
        final tags = _stringList(entry.value);
        for (final tag in tags) {
          if (!shotVocabulary.contains(tag)) {
            errors.add('U${index + 1}/S${shotIndex + 1} 的标签「$tag」不在受控词表里');
          }
        }
        shotTags[shotIndex] = tags;
      }
    }
    byIndex[index] = (tags: unitTags, shots: shotTags);
  }

  if (errors.isNotEmpty) return (units: units, errors: errors);

  return (
    units: [
      for (var i = 0; i < units.length; i++)
        if (byIndex[i] case final applied?)
          units[i].copyWith(
            tags: applied.tags,
            tagsStale: false,
            shots: [
              for (var s = 0; s < units[i].shots.length; s++)
                if (applied.shots[s] case final tags?)
                  units[i].shots[s].copyWith(tags: tags, tagsStale: false)
                else
                  units[i].shots[s],
            ],
          )
        else
          units[i],
    ],
    errors: const [],
  );
}

List<String> _stringList(Object? raw) => [
      for (final item in (raw is List ? raw : const []))
        if (item is String && item.trim().isNotEmpty) item.trim(),
    ];
