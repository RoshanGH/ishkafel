import 'dart:io';

import 'package:path/path.dart' as p;

import '../ffmpeg/ffprobe_service.dart';
import '../ffmpeg/process_runner.dart';
import 'bgm_library.dart';
import 'bgm_cache.dart';

/// 配乐缓存：全应用共用一份（同一首曲子被多个任务用到时只下一次）
BgmCache bgmCache(Directory dataDir) => BgmCache(
      library: BgmLibrary(),
      cacheDir: Directory(p.join(dataDir.path, 'bgm_cache')),
      // 缓存里可能躺着上次下崩的半截文件、或者地址失效时返回的错误页——
      // 解不出来就删掉重下，别等到导出时 ffmpeg 报一个看不懂的错。
      //
      // 用 playable 而不是 probe：后者解析的是**视频**信息，纯音频文件会以
      // 「没有视频流」抛错，把好好的配乐判成坏的
      verify: FfprobeService(run: const ResolvingProcessRunner().call).playable,
    );
