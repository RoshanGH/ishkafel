import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/commands/unit_command.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

void main() {
  late Directory dir;
  late FileTaskRepository repo;

  RenewTask task({int? pinned, List<Shot> shots = const []}) => RenewTask(
        id: 't1',
        name: '拼片',
        sourcePath: null,
        status: RenewTaskStatus.ready,
        createdAt: DateTime.utc(2026, 9, 14),
        updatedAt: DateTime.utc(2026, 9, 14),
        units: [
          SemanticUnit(
            uid: 'u0',
            index: 0,
            startMs: 0,
            endMs: 6000,
            transcript: '',
            hasSource: false,
            baseCandidateId: pinned,
            shots: shots,
          ),
        ],
        replacementsByUid: {
          'u0': UnitReplacement.whole([7, 8], previewId: 7),
        },
      );

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('unit_base');
    repo = FileTaskRepository(dir);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<Map<String, dynamic>> run(String what, {int unit = 0}) async {
    await repo.save(await repo.findById('t1') ?? task());
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runUnitCommand(
      rest: [what, 't1'],
      dataDir: dir,
      unit: unit,
      out: out,
      err: err,
      holder: 'test',
    );
    return {
      'code': code,
      'out': out.toString(),
      'err': err.toString(),
    };
  }

  group('unit base：先看清楚再决定', () {
    test('报出底片是谁', () async {
      await repo.save(task());
      final r = await run('base');

      expect(r['code'], 0);
      final json = jsonDecode(r['out'] as String) as Map<String, dynamic>;
      expect((json['base'] as Map)['kind'], 'material');
      expect((json['base'] as Map)['candidateId'], 7);
    });

    test('报出能不能切', () async {
      await repo.save(task());
      final json =
          jsonDecode((await run('base'))['out'] as String) as Map<String, dynamic>;

      expect(json['canSegment'], isTrue);
      expect(json['pinned'], isFalse);
    });

    test('报出切下去会掉什么——Agent 要据此判断值不值', () async {
      await repo.save(task());
      final json =
          jsonDecode((await run('base'))['out'] as String) as Map<String, dynamic>;

      expect((json['segmentWouldDrop'] as Map)['otherCandidates'], 1,
          reason: '选了 7 和 8，固定成 7 会掉 8');
    });

    test('固定过之后报 pinned 与镜头数', () async {
      await repo.save(task(pinned: 7, shots: const [
        Shot(startMs: 0, endMs: 3000),
        Shot(startMs: 3000, endMs: 6000),
      ]));
      final json =
          jsonDecode((await run('base'))['out'] as String) as Map<String, dynamic>;

      expect(json['pinned'], isTrue);
      expect(json['pinnedCandidateId'], 7);
      expect(json['shots'], 2);
    });

    test('单元下标越界要点名，不静默跳过', () async {
      await repo.save(task());
      final r = await run('base', unit: 9);

      expect(r['code'], isNot(0));
      expect(r['err'], contains('--unit'));
    });
  });

  group('unit unpin：换底片', () {
    test('清掉底片标记、镜头和挂在上面的选择', () async {
      await repo.save(task(pinned: 7, shots: const [
        Shot(startMs: 0, endMs: 3000),
        Shot(startMs: 3000, endMs: 6000),
      ]));
      final r = await run('unpin');

      expect(r['code'], 0);
      final saved = await repo.findById('t1');
      expect(saved!.units!.first.baseCandidateId, isNull);
      expect(saved.units!.first.shots, isEmpty);
    });

    test('本来就没固定过：说清楚，不是静默成功', () async {
      await repo.save(task());
      final r = await run('unpin');

      expect(r['code'], isNot(0));
      expect(r['err'], contains('没固定过'));
    });
  });
}
