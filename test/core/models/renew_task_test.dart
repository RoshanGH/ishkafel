import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/video_info.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/models/tag_group_ref.dart';
import 'package:ishkafel/core/storage/edit_stamp.dart';
import 'package:ishkafel/core/storage/task_log.dart';

void main() {
  final task = RenewTask(
    id: 't1',
    name: '滴露_植源喷雾_XCT',
    sourcePath: '/tmp/a.mp4',
    miaoaVideoId: '44888',
    videoInfo: const VideoInfo(
        width: 1080, height: 1920, duration: Duration(seconds: 96), fps: 30, fileSizeBytes: 1),
    coverPath: '/tmp/cover.jpg',
    status: RenewTaskStatus.analyzing,
    createdAt: DateTime.utc(2026, 7, 29),
    updatedAt: DateTime.utc(2026, 7, 29),
  );

  test('copyWith 返回新对象且不改原对象（不可变）', () {
    final updated = task.copyWith(status: RenewTaskStatus.ready);
    expect(updated.status, RenewTaskStatus.ready);
    expect(task.status, RenewTaskStatus.analyzing);
    expect(updated.id, task.id);
    expect(identical(updated, task), false);
  });

  test('toJson/fromJson 往返一致（含可空字段）', () {
    expect(RenewTask.fromJson(task.toJson()), task);
    final minimal = RenewTask(
      id: 't2', name: 'n', sourcePath: '/x.mp4',
      status: RenewTaskStatus.analyzing,
      createdAt: DateTime.utc(2026, 1, 1), updatedAt: DateTime.utc(2026, 1, 1),
    );
    expect(RenewTask.fromJson(minimal.toJson()), minimal);
    expect(minimal.videoInfo, isNull);
  });

  test('status 序列化为稳定字符串（存储契约，不许改名）', () {
    expect(RenewTaskStatus.analyzing.name, 'analyzing');
    expect(RenewTaskStatus.ready.name, 'ready');
    expect(RenewTaskStatus.values, hasLength(2),
        reason: '项目只有「分析中 → 可编辑」两个阶段，没有终态——'
            '有始有终的是每一次导出');
  });

  test('旧库里那些已经废掉的状态一律读成 ready，不是让任务消失', () {
    // exported 曾经存在但**从来没有一处代码把它设上过**；
    // awaitingCut / picking 对应的是已经合并掉的两个页面
    for (final legacy in ['awaitingCut', 'picking', 'editing', 'exported']) {
      final json = task.toJson()..['status'] = legacy;
      final parsed = RenewTask.fromJson(json);
      expect(parsed.status, RenewTaskStatus.ready,
          reason: '这两个状态对应的是已经合并掉的两个页面，'
              '但用户硬盘上的任务不该因此打不开');
      expect(parsed.units, task.units);
    }
  });

  test('未知 status（新版本写入的状态）回退到安全值而不是让整条任务消失', () {
    final json = task.toJson()..['status'] = 'exporting';
    final parsed = RenewTask.fromJson(json);
    expect(parsed.status, RenewTaskStatus.ready);
    expect(parsed.id, task.id);
  });

  test('status 字段缺失或类型不对时同样回退，不抛异常', () {
    final missing = task.toJson()..remove('status');
    expect(RenewTask.fromJson(missing).status, RenewTaskStatus.ready);
    final wrongType = task.toJson()..['status'] = 42;
    expect(RenewTask.fromJson(wrongType).status, RenewTaskStatus.ready);
  });

  test('旧 JSON（无 units 键）解析为 units == null（向后兼容）', () {
    final json = task.toJson()..remove('units');
    final parsed = RenewTask.fromJson(json);
    expect(parsed.units, isNull);
  });

  test('units 序列化往返一致且深度相等', () {
    final withUnits = task.copyWith(units: const [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 9000,
        transcript: '台词',
        shots: [Shot(startMs: 0, endMs: 9000)],
      ),
    ]);
    final parsed = RenewTask.fromJson(withUnits.toJson());
    expect(parsed, withUnits);
    expect(parsed.units!.single.shots.single.endMs, 9000);
  });

  test('旧 JSON（无 asrSentences 键）解析为 asrSentences == null（向后兼容）', () {
    final json = task.toJson()..remove('asrSentences');
    final parsed = RenewTask.fromJson(json);
    expect(parsed.asrSentences, isNull);
  });

  test('asrSentences（含字级时间戳）序列化往返一致且深度相等', () {
    final withAsr = task.copyWith(asrSentences: const [
      AsrSentence(
        startMs: 0,
        endMs: 4100,
        text: '第一句',
        words: [
          AsrWord(startMs: 0, endMs: 1000, text: '第', confidence: 0.9),
          AsrWord(startMs: 1000, endMs: 4100, text: '一句'),
        ],
      ),
    ]);
    final parsed = RenewTask.fromJson(withAsr.toJson());
    expect(parsed, withAsr);
    expect(parsed.asrSentences!.single.words.first.confidence, 0.9);
  });

  test('analysisError 序列化往返一致', () {
    final failed = task.copyWith(analysisError: '网络超时，请重试');
    final parsed = RenewTask.fromJson(failed.toJson());
    expect(parsed, failed);
    expect(parsed.analysisError, '网络超时，请重试');
  });

  test('旧 JSON（无 analysisError 键）解析为 analysisError == null（向后兼容）', () {
    final json = task.toJson()..remove('analysisError');
    final parsed = RenewTask.fromJson(json);
    expect(parsed.analysisError, isNull);
  });

  group('两个标签组（阶段②检索候选素材的键）', () {
    test('unitTagGroup / shotTagGroup 序列化往返一致', () {
      final tagged = task.copyWith(
        unitTagGroups: [const TagGroupRef(id: 1279, name: '衣清.消毒液')],
        shotTagGroups: [const TagGroupRef(id: 136, name: '画面类型')],
      );
      final parsed = RenewTask.fromJson(tagged.toJson());
      expect(parsed, tagged);
      expect(parsed.unitTagGroup!.id, 1279);
      expect(parsed.unitTagGroup!.name, '衣清.消毒液');
      expect(parsed.shotTagGroup!.id, 136);
      expect(parsed.shotTagGroup!.name, '画面类型');
    });

    test('旧 JSON（无这两个键）照常读出，不让整条任务从列表消失', () {
      final json = task.toJson()
        ..remove('unitTagGroup')
        ..remove('shotTagGroup');
      final parsed = RenewTask.fromJson(json);
      expect(parsed.unitTagGroup, isNull);
      expect(parsed.shotTagGroup, isNull);
      expect(parsed.id, task.id, reason: '其余字段必须完好');
    });

    test('字段类型不对（脏数据）时回退为 null，同样不抛异常', () {
      final json = task.toJson()
        ..['unitTagGroup'] = '衣清.消毒液'
        ..['shotTagGroup'] = {'id': '136', 'name': 42};
      final parsed = RenewTask.fromJson(json);
      expect(parsed.unitTagGroup, isNull);
      expect(parsed.shotTagGroup, isNull);
      expect(parsed.name, task.name);
    });

    test('copyWith 不传标签组时沿用原值（不可变，返回新对象）', () {
      final tagged =
          task.copyWith(unitTagGroups: [const TagGroupRef(id: 1, name: 'g')]);
      final renamed = tagged.copyWith(name: '改名');
      expect(renamed.unitTagGroup, const TagGroupRef(id: 1, name: 'g'));
      expect(task.unitTagGroup, isNull, reason: '原对象不得被就地修改');
    });
  });

  group('阶段②替换方案：按单元的身份记', () {
    /// 方案曾经是一个按位置对齐的数组，于是每挪一次、每删一次单元都要人工
    /// 把它搬一遍——2026-09-08 真机上就是这么错的。现在按单元自己的身份记，
    /// 怎么挪都还是它。界面和 CLI 照旧按位置说话，在存取这一步翻译。
    final units = [
      const SemanticUnit(
          uid: 'a', index: 0, startMs: 0, endMs: 1000, transcript: '一'),
      const SemanticUnit(
          uid: 'b', index: 1, startMs: 1000, endMs: 2000, transcript: '二'),
      const SemanticUnit(
          uid: 'c', index: 2, startMs: 2000, endMs: 3000, transcript: '三'),
    ];
    final withUnits = task.copyWith(units: units);

    test('序列化往返一致且深度相等', () {
      // 「保留原片」= 没定过方案，不占一格（存盘时按位置写占位，
      // 读回来再收掉）
      final picked = withUnits.copyWith(replacementsByUid: {
        'a': UnitReplacement.whole([11, 22]),
        'c': UnitReplacement.perShot({
          1: [33]
        }),
      });

      final parsed =
          RenewTask.fromJson(jsonDecode(jsonEncode(picked.toJson())));

      expect(parsed, picked);
      expect(parsed.replacementsByUid['a']!.wholeCandidateIds, [11, 22]);
      expect(parsed.replacementsByUid['c']!.shotCandidateIds[1], [33]);
    });

    test('挪动单元之后，方案还挂在原来那个单元上', () {
      final picked = withUnits.copyWith(
          replacementsByUid: RenewTask.byUid(units, [
        UnitReplacement.whole([11]),
        UnitReplacement.keepOriginal(),
        UnitReplacement.keepOriginal(),
      ]));

      // 把第一个挪到最后（列表顺序就是成片顺序）
      final moved = [units[1], units[2], units[0]];
      final after = picked.copyWith(units: moved);

      expect(after.replacementsFor(moved).last.wholeCandidateIds, [11],
          reason: '按位置记的话，挑给第一句的素材会留在第一格——'
              '2026-09-08 真机上的原话：「那个替换的镜头没有跟着 U2 走」');
    });

    test('老存档按位置存的，读出来对到当时那几个单元上', () {
      final json = withUnits.toJson()
        ..['replacements'] = [
          {'mode': 'whole', 'wholeCandidateIds': [1]},
          {'mode': 'keepOriginal'},
          {'mode': 'keepOriginal'},
        ];

      final parsed = RenewTask.fromJson(json);

      expect(parsed.replacementsByUid['a']!.wholeCandidateIds, [1]);
    });

    test('旧 JSON（无 replacements 键）照常读出，不让整条任务从列表消失', () {
      final json = withUnits.toJson()..remove('replacements');

      final parsed = RenewTask.fromJson(json);

      expect(parsed.replacementsByUid, isEmpty);
      expect(parsed.id, task.id, reason: '其余字段必须完好');
    });

    test('replacements 类型不对（脏数据）时当作没选材，不抛异常', () {
      final json = withUnits.toJson()..['replacements'] = '整体替换';

      final parsed = RenewTask.fromJson(json);

      expect(parsed.replacementsByUid, isEmpty);
      expect(parsed.name, task.name);
    });

    test('单条畸形只跳过那一条，其余照旧挂在自己的单元上', () {
      final json = withUnits.toJson()
        ..['replacements'] = [
          {'mode': 'whole', 'wholeCandidateIds': [1]},
          'not-a-map',
          {'mode': 'whole', 'wholeCandidateIds': [2]},
        ];

      final parsed = RenewTask.fromJson(json);

      expect(parsed.replacementsByUid['a']!.wholeCandidateIds, [1]);
      expect(parsed.replacementsByUid['c']!.wholeCandidateIds, [2],
          reason: '坏的那条只影响它自己，后面的不能整体错位');
      expect(parsed.replacementsByUid.containsKey('b'), isFalse);
    });

    test('按位置铺开时，没定过方案的那格是保留原片', () {
      final picked = withUnits.copyWith(
          replacementsByUid: {'b': UnitReplacement.whole([9])});

      final list = picked.replacementsFor(units);

      expect(list, hasLength(3));
      expect(list[0].mode, ReplacementMode.keepOriginal);
      expect(list[1].wholeCandidateIds, [9]);
    });

    test('对外只读', () {
      final picked = withUnits
          .copyWith(replacementsByUid: {'a': UnitReplacement.keepOriginal()});

      expect(() => picked.replacementsFor(units).add(UnitReplacement.keepOriginal()),
          throwsUnsupportedError);
      expect(() => picked.replacementsByUid['x'] = UnitReplacement.keepOriginal(),
          throwsUnsupportedError);
    });
  });

  test('copyWith(clearAnalysisError: true) 清空 analysisError，其余字段不变', () {
    final failed = task.copyWith(analysisError: '分析失败（模拟）');
    final cleared = failed.copyWith(clearAnalysisError: true);
    expect(cleared.analysisError, isNull);
    expect(cleared.status, failed.status);
    expect(cleared.id, failed.id);
    // 不传 clearAnalysisError 时，普通 copyWith 不会清空既有错误信息
    final untouched = failed.copyWith(name: '改名');
    expect(untouched.analysisError, '分析失败（模拟）');
  });

  /// 真机上撞到的：一个 35 镜分析完、方案提交过、片子也导出成功四次的任务，
  /// 列表里挂着红色「分析失败：上次分析被中断，请重新分析」。
  ///
  /// 原因是 `status` 早就回到 ready，而 analysisError 还留着那次中断时写下的
  /// 话——**七处地方把状态置成 ready，没有一处记得清它**。人看到的是一条
  /// 好端端的任务显示失败，点「重试」还要再花一次分析的钱。
  ///
  /// 「ready 且带着分析错误」是个不可能的状态，不该指望七个调用点各自记得。
  group('分析成功就不该再挂着分析错误', () {
    test('状态回到 ready 时，陈旧的分析错误自动清掉', () {
      final stalled = task.copyWith(
        status: RenewTaskStatus.analyzing,
        analysisError: '上次分析被中断（应用退出或异常关闭），请重新分析',
      );

      final done = stalled.copyWith(status: RenewTaskStatus.ready);

      expect(done.analysisError, isNull);
    });

    test('还在分析中的，错误照留——那是真的出过错', () {
      final failed = task.copyWith(
        status: RenewTaskStatus.analyzing,
        analysisError: '网络超时，请重试',
      );

      expect(failed.analysisError, '网络超时，请重试');
    });

    test('已经是 ready 的任务重新分析又失败了，那个错要留住', () {
      // 分析失败是「保持原状态、只记错误」——ready 的任务重分析失败，
      // ready + 错误是合法的，不能一刀切
      final ready = task.copyWith(status: RenewTaskStatus.ready);
      final failedAgain = ready.copyWith(analysisError: '转写失败');

      expect(failedAgain.analysisError, '转写失败');
    });
  });

  test('editedBy 存得住、读得回', () {
    final task = RenewTask(
      id: 't_1',
      name: '测试任务',
      status: RenewTaskStatus.ready,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      editedBy: {
        'u:u-abc/s:1': EditStamp(by: ActorKind.human, at: DateTime.now()),
      },
    );
    final back = RenewTask.fromJson(task.toJson());
    expect(back.editedBy['u:u-abc/s:1']!.by, ActorKind.human);
  });

  test('读不懂的戳被丢掉，其余的照常读回来——一个坏戳不许废掉整条任务', () {
    final raw = RenewTask(
      id: 't_1',
      name: '测试任务',
      status: RenewTaskStatus.ready,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      editedBy: {'u:good': EditStamp(by: ActorKind.agent, at: DateTime.now())},
    ).toJson();
    (raw['editedBy'] as Map)['u:bad'] = {'by': 'human'}; // 缺 at

    final back = RenewTask.fromJson(raw);
    expect(back.editedBy.keys, ['u:good']);
  });
}
