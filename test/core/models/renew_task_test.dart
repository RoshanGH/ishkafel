import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/video_info.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';

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
}
