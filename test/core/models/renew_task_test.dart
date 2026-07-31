import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/video_info.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/models/tag_group_ref.dart';

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
    final updated = task.copyWith(status: RenewTaskStatus.awaitingCut);
    expect(updated.status, RenewTaskStatus.awaitingCut);
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
    expect(RenewTaskStatus.awaitingCut.name, 'awaitingCut');
    expect(RenewTaskStatus.picking.name, 'picking');
    expect(RenewTaskStatus.exported.name, 'exported');
  });

  test('未知 status（新版本写入的状态）回退到安全值而不是让整条任务消失', () {
    final json = task.toJson()..['status'] = 'exporting';
    final parsed = RenewTask.fromJson(json);
    expect(parsed.status, RenewTaskStatus.picking);
    expect(parsed.id, task.id);
  });

  test('status 字段缺失或类型不对时同样回退，不抛异常', () {
    final missing = task.toJson()..remove('status');
    expect(RenewTask.fromJson(missing).status, RenewTaskStatus.picking);
    final wrongType = task.toJson()..['status'] = 42;
    expect(RenewTask.fromJson(wrongType).status, RenewTaskStatus.picking);
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
        unitTagGroup: const TagGroupRef(id: 1279, name: '衣清.消毒液'),
        shotTagGroup: const TagGroupRef(id: 136, name: '画面类型'),
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
          task.copyWith(unitTagGroup: const TagGroupRef(id: 1, name: 'g'));
      final renamed = tagged.copyWith(name: '改名');
      expect(renamed.unitTagGroup, const TagGroupRef(id: 1, name: 'g'));
      expect(task.unitTagGroup, isNull, reason: '原对象不得被就地修改');
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
}
