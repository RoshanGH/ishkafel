import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/task_view.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/models/video_info.dart';
import 'package:ishkafel/core/replacement/picked_material.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/core/time/rational.dart';

import '../support/seed_task.dart';
import 'dart:io';

void main() {
  late Directory dataDir;
  setUp(() => dataDir = Directory.systemTemp.createTempSync('ishkafel_sig'));
  tearDown(() => dataDir.deleteSync(recursive: true));

  /// 带真实两个镜头的任务（ASR 台词「甲乙」），都有听到和字幕
  RenewTask taskWithShots() => RenewTask(
        id: 't1', name: '测试', status: RenewTaskStatus.ready,
        createdAt: DateTime(2026, 9, 20), updatedAt: DateTime(2026, 9, 20),
        videoInfo: VideoInfo(
            width: 1080, height: 1920, fps: 30,
            duration: const Duration(milliseconds: 2000),
            fpsExact: Rational.fps30,
            fileSizeBytes: 0),
        asrSentences: const [
          AsrSentence(startMs: 0, endMs: 900, text: '甲乙', words: [
            AsrWord(startMs: 0, endMs: 400, text: '甲'),
            AsrWord(startMs: 400, endMs: 900, text: '乙'),
          ]),
        ],
        units: const [
          SemanticUnit(
            uid: 'u0', index: 0, startMs: 0, endMs: 2000, transcript: '甲乙',
            shots: [
              Shot(startMs: 0, endMs: 1000),
              Shot(startMs: 1000, endMs: 2000),
            ],
          ),
        ],
      );

  test('task 里只留一句信号和一条去处，不留细节', () async {
    final task = await seedTask(dataDir);
    final sub = taskToJson(task)['subtitle'] as Map<String, dynamic>;
    expect(sub.keys,
        containsAll(['shotsWith', 'shotsWithout', 'handEdited', 'suspect']));
    expect(sub['note'], contains('ishkafel subtitle'),
        reason: '不给它去处，它永远不知道该敲哪条命令');
    expect(sub.containsKey('shots'), isFalse,
        reason: 'task 是现状概览，不是数据倾倒场——'
            '#1 那条任务 units 已经占了 17KB 的 99.8%');
  });

  test('还没分析时说「还没分析」', () async {
    final task = await seedTask(dataDir);
    final sub = taskToJson(task)['subtitle'] as Map<String, dynamic>;
    expect(sub['shotsWith'], 0, reason: '没有镜头数据');
    expect(sub['shotsWithout'], 0);
    expect(sub['note'], contains('还没分析'));
  });

  test('真的数一遍：第一镜听得到有字幕，第二镜没台词', () {
    final task = taskWithShots();
    final sub = taskToJson(task)['subtitle'] as Map<String, dynamic>;
    // ASR 台词「甲乙」只到 900ms，所以第一个镜头（0-1000ms）会听到，
    // 第二个镜头（1000-2000ms）没有台词
    expect(sub['shotsWith'], 1,
        reason: '恒为 0 的话这个信号比没有更糟——Agent 会因为「没查出毛病」放过真问题');
    expect(sub['shotsWithout'], 1);
    expect(sub['suspect'], 0, reason: '没有检出任何问题');
    expect(sub['note'], contains('不含素材烧字'),
        reason: 'note 要说明 suspect 不含烧字检查，否则是静默降级');
  });

  /// 整体替换选了候选，但素材时长还没探出——跟 subtitle_view_test.dart 里的
  /// taskWithUnknownWholeDuration 是同一种夹具
  RenewTask taskWithUnknownWholeDuration() => RenewTask(
        id: 't_unknown', name: '素材时长未知', status: RenewTaskStatus.ready,
        createdAt: DateTime(2026, 9, 20), updatedAt: DateTime(2026, 9, 20),
        videoInfo: VideoInfo(
            width: 1080, height: 1920, fps: 30,
            duration: const Duration(milliseconds: 2000),
            fpsExact: Rational.fps30,
            fileSizeBytes: 0),
        asrSentences: const [
          AsrSentence(startMs: 0, endMs: 900, text: '甲乙', words: [
            AsrWord(startMs: 0, endMs: 400, text: '甲'),
            AsrWord(startMs: 400, endMs: 900, text: '乙'),
          ]),
        ],
        units: const [
          SemanticUnit(
            uid: 'u0', index: 0, startMs: 0, endMs: 2000, transcript: '甲乙',
            shots: [
              Shot(startMs: 0, endMs: 1000),
              Shot(startMs: 1000, endMs: 2000),
            ],
          ),
        ],
        replacementsByUid: {
          'u0': UnitReplacement.whole(const [1]),
        },
        // 挑了候选（id 1），但这条素材没有 durationMs——时长还没探出来
        pickedMaterials: const [PickedMaterial(id: 1, name: '候选')],
      );

  test('算不准的时候，要说算不准，不许报成「查过、没问题」', () {
    final task = taskWithUnknownWholeDuration();
    final sub = taskToJson(task)['subtitle'] as Map<String, dynamic>;
    expect(sub['note'], contains('算不准'),
        reason: '这条线上已经三次把某一态混进「没问题」里了');
    expect(sub['note'], contains('ishkafel'),
        reason: '每一态都要给一条能照做的去处');
    expect(sub['shotsWithout'], 0,
        reason: '算不准时不许报假的计数');
    expect(sub['shotsWith'], 0);
    expect(sub['suspect'], 0);
  });
}
