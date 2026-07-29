import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ffmpeg/ffprobe_service.dart';
import 'package:ishkafel/core/ffmpeg/thumbnail_service.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';
import 'package:ishkafel/features/import_flow/import_service.dart';
import 'dart:convert';

const probeJson = {
  'streams': [
    {'codec_type': 'video', 'width': 1080, 'height': 1920, 'r_frame_rate': '30/1'},
  ],
  'format': {'duration': '96.2', 'size': '100'},
};

void main() {
  late Directory tempDir;
  late ImportService service;
  late FileTaskRepository repo;
  final ffmpegCalls = <List<String>>[];

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ishkafel_import_');
    repo = FileTaskRepository(tempDir);
    ffmpegCalls.clear();
    service = ImportService(
      repository: repo,
      ffprobe: FfprobeService(
          run: (_, _) async => ProcessResult(1, 0, jsonEncode(probeJson), '')),
      thumbnails: ThumbnailService(run: (_, args) async {
        ffmpegCalls.add(args);
        return ProcessResult(1, 0, '', '');
      }),
      coversDir: Directory('${tempDir.path}/covers'),
      idGenerator: () => 'fixed-id',
      clock: () => DateTime.utc(2026, 7, 29, 12),
    );
  });

  tearDown(() async => tempDir.delete(recursive: true));

  test('导入本地文件：建任务、抽封面、落库', () async {
    final task = await service.importLocalFile('/videos/滴露_测试片.mp4');
    expect(task.id, 'fixed-id');
    expect(task.name, '滴露_测试片');
    expect(task.status, RenewTaskStatus.analyzing);
    expect(task.videoInfo!.width, 1080);
    expect(task.coverPath, endsWith('covers/fixed-id.jpg'));
    // 封面命令确实指向源视频
    expect(ffmpegCalls.single, contains('/videos/滴露_测试片.mp4'));
    // 已落库
    expect(await repo.findById('fixed-id'), task);
  });

  test('ffprobe 失败时不落库并向上抛错', () async {
    final failing = ImportService(
      repository: repo,
      ffprobe: FfprobeService(run: (_, _) async => ProcessResult(1, 1, '', 'bad file')),
      thumbnails: ThumbnailService(run: (_, _) async => ProcessResult(1, 0, '', '')),
      coversDir: Directory('${tempDir.path}/covers'),
    );
    await expectLater(failing.importLocalFile('/v/x.mp4'), throwsException);
    expect(await repo.findAll(), isEmpty);
  });
}
