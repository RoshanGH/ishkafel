import '../core/export/export_plan.dart';
import '../core/models/renew_task.dart';
import '../core/models/semantic_unit.dart';

/// Agent 提交的一条**完整方案**：每个单元用什么，一次说清。
///
/// 为什么不是「每个位置挑几个候选，再做笛卡尔积」：产品要求是**产出的每一条
/// 都能用**，而笛卡尔积隐含「每个位置的每个候选都独立可用、任意搭配都成立」
/// ——这恰恰是「挑的时候要看前后是否顺畅」所否定的前提（spec 第四节）。
///
/// 一条方案是调用方整体设计过的，所以每一条都能用。
class SubmittedPlan {
  /// 给人看的名字，会出现在导出文件名里
  final String name;

  /// 单元下标 → 这个单元怎么处理
  final Map<int, PlanUnit> units;

  const SubmittedPlan({required this.name, required this.units});
}

/// 一个单元在某条方案里的处理方式
class PlanUnit {
  /// `keepOriginal` / `whole` / `perShot`
  final String mode;

  /// 整体替换用的候选 id
  final int? material;

  /// 镜头下标 → 候选 id
  final Map<int, int> shots;

  const PlanUnit({required this.mode, this.material, this.shots = const {}});
}

/// 校验结果。[errors] 非空即为不通过
class PlanValidation {
  final List<SubmittedPlan> plans;
  final List<String> errors;

  const PlanValidation({this.plans = const [], this.errors = const []});

  bool get ok => errors.isEmpty;
}

/// 解析并校验 Agent 提交的方案。
///
/// **外包出去的是「判断」，不是「数据结构的定义权」**（spec 第三节）。
/// 调用方可以说「这个镜头用 116719」，但不能凭空造一个不存在的单元下标、
/// 不能引用没检索到的素材、也不能给一个模式却不给对应的取值。
///
/// 不合格就**整批拒绝**并一次点全所有问题——让它改一个提交一次是在浪费
/// 双方的时间。
PlanValidation parsePlans(Object? raw, RenewTask task) {
  final units = task.units;
  if (units == null) {
    return const PlanValidation(errors: ['这个任务还没分析完，没有单元可编排']);
  }
  if (raw is! Map) return const PlanValidation(errors: ['提交的内容不是一个 JSON 对象']);
  final list = raw['plans'];
  if (list is! List || list.isEmpty) {
    return const PlanValidation(errors: ['plans 必须是一个非空数组']);
  }

  final errors = <String>[];
  final plans = <SubmittedPlan>[];
  final names = <String>{};

  for (var i = 0; i < list.length; i++) {
    final where = '第 ${i + 1} 条方案';
    final item = list[i];
    if (item is! Map) {
      errors.add('$where 不是一个对象');
      continue;
    }
    final name = '${item['name'] ?? ''}'.trim();
    if (name.isEmpty) {
      errors.add('$where 缺少 name——它会出现在导出文件名里');
      continue;
    }
    if (!names.add(name)) {
      // 重名会让导出文件互相覆盖，事后根本分不清哪条是哪条
      errors.add('$where 的名字「$name」和前面重复了');
    }

    final rawUnits = item['units'];
    if (rawUnits is! List || rawUnits.isEmpty) {
      errors.add('$where 的 units 必须是一个非空数组');
      continue;
    }

    final parsed = <int, PlanUnit>{};
    for (final u in rawUnits) {
      final problem = _parseUnit(u, units, parsed, where);
      if (problem != null) errors.add(problem);
    }
    // 同一条素材不能在一条成片里出现两次——同一个画面重复出现，一眼就能
    // 看出来。GUI 在挑的那一刻就拦；这里是 Agent 提交整条方案的对应关口
    final seen = <int, String>{};
    for (final e in parsed.entries) {
      final positions = <(int?, String)>[
        (e.value.material, 'U${e.key + 1}'),
        for (final shot in e.value.shots.entries)
          (shot.value, 'U${e.key + 1} 的 S${shot.key + 1}'),
      ];
      for (final (id, place) in positions) {
        if (id == null) continue;
        final before = seen[id];
        if (before != null) {
          errors.add('$where 里素材 $id 用了两次（$before 和 $place）'
              '——同一条素材不能在一条成片里出现两次');
        } else {
          seen[id] = place;
        }
      }
    }
    plans.add(SubmittedPlan(name: name, units: parsed));
  }

  return errors.isEmpty
      ? PlanValidation(plans: plans)
      : PlanValidation(errors: errors);
}

String? _parseUnit(
  Object? raw,
  List<SemanticUnit> units,
  Map<int, PlanUnit> into,
  String where,
) {
  if (raw is! Map) return '$where 里有一项不是对象';
  final index = raw['unit'];
  if (index is! int || index < 0 || index >= units.length) {
    return '$where 引用了不存在的单元 $index（共 ${units.length} 个）';
  }
  if (into.containsKey(index)) {
    return '$where 给 U${index + 1} 指定了两次';
  }

  final mode = '${raw['mode'] ?? ''}';
  switch (mode) {
    case 'keepOriginal':
      into[index] = const PlanUnit(mode: 'keepOriginal');
      return null;

    case 'whole':
      final material = raw['material'];
      if (material is! int) {
        return '$where 的 U${index + 1} 是整体替换，但没给 material';
      }
      into[index] = PlanUnit(mode: 'whole', material: material);
      return null;

    case 'perShot':
      final shots = raw['shots'];
      if (shots is! Map || shots.isEmpty) {
        return '$where 的 U${index + 1} 是镜头替换，但没给 shots';
      }
      final total = units[index].shots.length;
      final picked = <int, int>{};
      for (final entry in shots.entries) {
        final shotIndex = int.tryParse('${entry.key}');
        if (shotIndex == null || shotIndex < 0 || shotIndex >= total) {
          return '$where 的 U${index + 1} 引用了不存在的镜头 ${entry.key}'
              '（共 $total 个）';
        }
        if (entry.value is! int) {
          return '$where 的 U${index + 1}/S${shotIndex + 1} 的素材 id 不是整数';
        }
        picked[shotIndex] = entry.value as int;
      }
      into[index] = PlanUnit(mode: 'perShot', shots: picked);
      return null;

    default:
      return '$where 的 U${index + 1} 的 mode 只能是 '
          'keepOriginal / whole / perShot，收到的是「$mode」';
  }
}

/// 把一条方案翻译成导出用的组合。
///
/// 没在方案里提到的单元一律**保留原片**——不猜、不补默认值：调用方没说的
/// 事，我们不替它决定。
ExportCombination toCombination(SubmittedPlan plan, List<SemanticUnit> units,
    {required int index}) {
  final segments = <ExportSegment>[];
  for (final unit in units) {
    final chosen = plan.units[unit.index];
    if (chosen == null || chosen.mode == 'keepOriginal') {
      segments.add(ExportSegment(
        unitIndex: unit.index,
        startMs: unit.startMs,
        endMs: unit.endMs,
      ));
      continue;
    }
    if (chosen.mode == 'whole') {
      segments.add(ExportSegment(
        unitIndex: unit.index,
        startMs: unit.startMs,
        endMs: unit.endMs,
        candidateId: chosen.material,
      ));
      continue;
    }
    for (var s = 0; s < unit.shots.length; s++) {
      final shot = unit.shots[s];
      segments.add(ExportSegment(
        unitIndex: unit.index,
        shotIndex: s,
        startMs: shot.startMs,
        endMs: shot.endMs,
        candidateId: chosen.shots[s],
      ));
    }
  }
  return ExportCombination(index: index, segments: segments);
}
