import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/plan_submission.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';

/// Agent 提交的方案要过校验。
///
/// **外包出去的是「判断」，不是「数据结构的定义权」**（spec 第三节）：
/// 调用方可以说「这个镜头用 116719」，但不能凭空造一个不存在的单元、
/// 不能给一个模式却不给对应的取值。不合格整批拒绝并一次点全所有问题——
/// 让它改一个提交一次是在浪费双方的时间。
void main() {
  _duplicateMaterialInPlanTests();
  final task = RenewTask(
    id: 't',
    name: 'n',
    sourcePath: '/tmp/a.mp4',
    status: RenewTaskStatus.ready,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
    units: [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 4000,
        transcript: 'A',
        shots: const [
          Shot(startMs: 0, endMs: 2000),
          Shot(startMs: 2000, endMs: 4000),
        ],
      ),
      SemanticUnit(
        index: 1,
        startMs: 4000,
        endMs: 8000,
        transcript: 'B',
        shots: const [Shot(startMs: 4000, endMs: 8000)],
      ),
    ],
  );

  PlanValidation parse(String json) => parsePlans(jsonDecode(json), task);

  group('收下合法的方案', () {
    test('三种模式都认', () {
      final result = parse('''
      {"plans":[{"name":"A线","units":[
        {"unit":0,"mode":"perShot","shots":{"1":116719}},
        {"unit":1,"mode":"whole","material":114799}
      ]}]}''');
      expect(result.ok, isTrue, reason: result.errors.join('；'));
      final plan = result.plans.single;
      expect(plan.name, 'A线');
      expect(plan.units[0]!.shots, {1: 116719});
      expect(plan.units[1]!.material, 114799);
    });

    test('没提到的单元保留原片——不猜、不补默认值', () {
      final result = parse(
          '{"plans":[{"name":"只换一个","units":[{"unit":1,"mode":"keepOriginal"}]}]}');
      expect(result.ok, isTrue);
      final combo =
          toCombination(result.plans.single, task.units!, index: 0);
      // U1 没提到 → 整段原片；U2 明确保留 → 也是原片
      expect(combo.segments.every((s) => s.candidateId == null), isTrue);
      expect(combo.segments.first.unitIndex, 0);
    });

    test('翻译成组合时，镜头替换按镜头逐段展开', () {
      final result = parse(
          '{"plans":[{"name":"x","units":[{"unit":0,"mode":"perShot","shots":{"1":9}}]}]}');
      final combo =
          toCombination(result.plans.single, task.units!, index: 3);
      expect(combo.index, 3);
      final u0 = combo.segments.where((s) => s.unitIndex == 0).toList();
      expect(u0, hasLength(2), reason: 'U1 有两个镜头，要展开成两段');
      expect(u0[0].candidateId, isNull, reason: 'S1 没挑，保留原片');
      expect(u0[1].candidateId, 9);
    });
  });

  group('挡住不合法的', () {
    test('不存在的单元', () {
      final result =
          parse('{"plans":[{"name":"x","units":[{"unit":9,"mode":"keepOriginal"}]}]}');
      expect(result.ok, isFalse);
      expect(result.errors.single, contains('不存在的单元'));
    });

    test('不存在的镜头', () {
      final result = parse(
          '{"plans":[{"name":"x","units":[{"unit":1,"mode":"perShot","shots":{"5":9}}]}]}');
      expect(result.ok, isFalse);
      expect(result.errors.single, contains('不存在的镜头'));
    });

    test('整体替换却没给素材', () {
      final result =
          parse('{"plans":[{"name":"x","units":[{"unit":0,"mode":"whole"}]}]}');
      expect(result.ok, isFalse);
      expect(result.errors.single, contains('没给 material'));
    });

    test('镜头替换却没给 shots', () {
      final result =
          parse('{"plans":[{"name":"x","units":[{"unit":0,"mode":"perShot"}]}]}');
      expect(result.ok, isFalse);
      expect(result.errors.single, contains('没给 shots'));
    });

    test('认不出的模式', () {
      final result =
          parse('{"plans":[{"name":"x","units":[{"unit":0,"mode":"随便"}]}]}');
      expect(result.ok, isFalse);
      expect(result.errors.single, contains('mode 只能是'));
    });

    test('缺名字——它会出现在导出文件名里', () {
      final result =
          parse('{"plans":[{"units":[{"unit":0,"mode":"keepOriginal"}]}]}');
      expect(result.ok, isFalse);
      expect(result.errors.single, contains('缺少 name'));
    });

    test('重名——导出文件会互相覆盖，事后分不清哪条是哪条', () {
      final result = parse('''
      {"plans":[
        {"name":"同名","units":[{"unit":0,"mode":"keepOriginal"}]},
        {"name":"同名","units":[{"unit":1,"mode":"keepOriginal"}]}
      ]}''');
      expect(result.ok, isFalse);
      expect(result.errors.single, contains('重复'));
    });

    test('同一个单元指定两次', () {
      final result = parse('''
      {"plans":[{"name":"x","units":[
        {"unit":0,"mode":"keepOriginal"},
        {"unit":0,"mode":"whole","material":1}
      ]}]}''');
      expect(result.ok, isFalse);
      expect(result.errors.single, contains('指定了两次'));
    });

    test('一次点全所有问题，不是发现一个就停', () {
      final result = parse('''
      {"plans":[
        {"name":"a","units":[{"unit":9,"mode":"keepOriginal"}]},
        {"units":[{"unit":0,"mode":"keepOriginal"}]},
        {"name":"c","units":[{"unit":0,"mode":"whole"}]}
      ]}''');
      expect(result.errors, hasLength(3));
    });

    test('空数组、非对象都挡住', () {
      expect(parse('{"plans":[]}').ok, isFalse);
      expect(parse('{}').ok, isFalse);
      expect(parsePlans('不是对象', task).ok, isFalse);
    });

    test('任务还没分析完时说清楚', () {
      final raw = RenewTask(
        id: 't',
        name: 'n',
        sourcePath: '/x',
        status: RenewTaskStatus.analyzing,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );
      final result = parsePlans({'plans': []}, raw);
      expect(result.ok, isFalse);
      expect(result.errors.single, contains('还没分析完'));
    });
  });
}

/// 同一条素材在一条方案里出现两次——提交那一刻就拒，不等导出去重才发现。
void _duplicateMaterialInPlanTests() {
  RenewTask taskOf() => RenewTask(
        id: 't',
        name: 'n',
        sourcePath: '/tmp/a.mp4',
        status: RenewTaskStatus.ready,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        units: [
          SemanticUnit(
            index: 0,
            startMs: 0,
            endMs: 4000,
            transcript: 'A',
            shots: const [Shot(startMs: 0, endMs: 4000)],
          ),
          SemanticUnit(
            index: 1,
            startMs: 4000,
            endMs: 8000,
            transcript: 'B',
            shots: const [Shot(startMs: 4000, endMs: 8000)],
          ),
        ],
      );

  test('整体替换与镜头替换共用同一条素材时点名拒绝', () {
    final validation = parsePlans({
      'plans': [
        {
          'name': '方案A',
          'units': [
            {'unit': 0, 'mode': 'whole', 'material': 101},
            {
              'unit': 1,
              'mode': 'perShot',
              'shots': {'0': 101},
            },
          ],
        },
      ],
    }, taskOf());
    expect(validation.ok, isFalse);
    expect(validation.errors.single, contains('素材 101 用了两次'));
    expect(validation.errors.single, contains('U1'));
    expect(validation.errors.single, contains('U2 的 S1'));
  });

  test('不同方案可以用同一条素材——限制只在一条成片内部', () {
    final validation = parsePlans({
      'plans': [
        {
          'name': '方案A',
          'units': [
            {'unit': 0, 'mode': 'whole', 'material': 101},
          ],
        },
        {
          'name': '方案B',
          'units': [
            {'unit': 1, 'mode': 'whole', 'material': 101},
          ],
        },
      ],
    }, taskOf());
    expect(validation.ok, isTrue);
  });
}
