import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/commands/unit_command.dart';
import 'package:ishkafel/core/audio/material_audio.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

/// 「人在界面上能拧的每个旋钮，Agent 都要能拧」——
/// 「原片这一镜的声音」这一路的命令行入口。
void main() {
  late Directory dir;
  late FileTaskRepository repo;

  RenewTask task() => RenewTask(
        id: 'r1',
        name: '有原片的任务',
        sourcePath: '/tmp/原片.mp4',
        units: const [
          SemanticUnit(
            uid: 'u0',
            index: 0,
            startMs: 0,
            endMs: 4000,
            transcript: 'U1',
            shots: [
              Shot(startMs: 0, endMs: 2000),
              Shot(startMs: 2000, endMs: 4000),
            ],
          ),
        ],
        status: RenewTaskStatus.ready,
        createdAt: DateTime.utc(2026, 9, 10),
        updatedAt: DateTime.utc(2026, 9, 10),
      );

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('ishkafel_src_audio_');
    repo = FileTaskRepository(dir);
    await repo.save(task());
  });

  tearDown(() => dir.deleteSync(recursive: true));

  Future<int> run(List<String> args, {int? unit, int? shot, String? audio,
      double? volume}) =>
      runUnitCommand(
        rest: args,
        dataDir: dir,
        unit: unit,
        shot: shot,
        audio: audio,
        volume: volume,
        out: StringBuffer(),
        err: StringBuffer(),
      );

  test('全片打底：设成人声', () async {
    expect(await run(['source-audio', 'r1'], audio: 'vocals'), 0);
    final saved = await repo.findById('r1');
    expect(saved!.sourceAudio.mode, MaterialAudioMode.vocals);
  });

  test('全片改回自动——auto 不是第五个档位，是「还没选过」', () async {
    await run(['source-audio', 'r1'], audio: 'vocals');
    expect(await run(['source-audio', 'r1'], audio: 'auto'), 0);
    expect((await repo.findById('r1'))!.sourceAudio.isAuto, isTrue);
  });

  test('镜头级：设了再 follow 回去', () async {
    expect(
        await run(['source-audio', 'r1'],
            unit: 0, shot: 1, audio: 'background', volume: 0.5),
        0);
    var shot = (await repo.findById('r1'))!.units![0].shots[1];
    expect(shot.sourceAudioMode, MaterialAudioMode.background);
    expect(shot.sourceAudioVolume, 0.5);

    expect(
        await run(['source-audio', 'r1'], unit: 0, shot: 1, audio: 'follow'),
        0);
    shot = (await repo.findById('r1'))!.units![0].shots[1];
    expect(shot.sourceAudioMode, isNull, reason: 'follow = 清掉覆盖');
  });

  test('改一镜不碰另一镜', () async {
    await run(['source-audio', 'r1'], unit: 0, shot: 1, audio: 'none');
    final shots = (await repo.findById('r1'))!.units![0].shots;
    expect(shots[0].sourceAudioMode, isNull);
    expect(shots[1].sourceAudioMode, MaterialAudioMode.none);
  });

  test('认不出的档位直接拒绝，不猜', () async {
    expect(await run(['source-audio', 'r1'], audio: '大点声'), isNot(0));
    expect((await repo.findById('r1'))!.sourceAudio.isAuto, isTrue);
  });

  test('全片那一层没有 follow；镜头那一层没有 auto', () async {
    expect(await run(['source-audio', 'r1'], audio: 'follow'), isNot(0));
    expect(
        await run(['source-audio', 'r1'], unit: 0, shot: 0, audio: 'auto'),
        isNot(0));
  });
}
