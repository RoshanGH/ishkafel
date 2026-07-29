import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'app/app.dart';
import 'core/ffmpeg/ffprobe_service.dart';
import 'core/ffmpeg/thumbnail_service.dart';
import 'core/storage/file_task_repository.dart';
import 'features/import_flow/import_service.dart';
import 'features/tasks/task_list_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final supportDir = await getApplicationSupportDirectory();
  final dataDir = Directory(p.join(supportDir.path, 'ishkafel_data'));
  final repository = FileTaskRepository(dataDir);
  final importService = ImportService(
    repository: repository,
    ffprobe: FfprobeService(),
    thumbnails: ThumbnailService(),
    coversDir: Directory(p.join(dataDir.path, 'covers')),
  );
  runApp(ProviderScope(
    overrides: [
      taskRepositoryProvider.overrideWithValue(repository),
      importServiceProvider.overrideWithValue(importService),
    ],
    child: const IshkafelApp(),
  ));
}
