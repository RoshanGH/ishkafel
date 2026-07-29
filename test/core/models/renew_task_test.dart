import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/video_info.dart';

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
}
