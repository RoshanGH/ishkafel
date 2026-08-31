import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../log/app_log.dart';
import 'miaoa_gateway.dart';

/// 把一张**本地图**变成妙啊能用的查询帧（OSS key）。
///
/// 为什么要有这一层：妙啊的以图搜视频只吃 OSS key
/// （`content search --like-image <fileKey>`），不吃本地文件。而复刻场景
/// 里最该拿去搜的那张图——**参考片这一镜的首帧**——恰恰只在本地：
/// 它是打标时 ffmpeg 抽出来的。
///
/// 于是这条最准的路一直是断的：手里攥着要复刻的那一帧，却只能先把它
/// 交给 AI 写成一句话，再拿那句话去匹配别人写的另一句话——中间隔着一层
/// 有损转译，同一个镜头两次写出来的措辞不一样，搜出来的东西就不一样。
///
/// **按内容指纹缓存**：同一张图只上传一次。文件名会变、路径会变，
/// 内容一样就是同一张——按路径判重会重复上传，按「文件在不在」判重
/// 会把上一张的结果放出来。
class QueryFrameUploader {
  final MiaoaGateway gateway;

  /// 上传落到哪个二级文件夹。这些图只是查询用的中间物，
  /// 单独放一处，别混进正经素材里
  final int folderId;

  /// 映射存哪儿（内容指纹 → OSS key）
  final Directory cacheDir;

  QueryFrameUploader({
    required this.gateway,
    required this.folderId,
    required this.cacheDir,
  });

  File get _index => File(p.join(cacheDir.path, 'query_frames.json'));

  Map<String, String> _read() {
    try {
      if (!_index.existsSync()) return {};
      final raw = jsonDecode(_index.readAsStringSync());
      if (raw is! Map) return {};
      return {
        for (final e in raw.entries)
          if (e.value is String) '${e.key}': e.value as String,
      };
    } catch (e) {
      AppLog.warn('查询帧索引读不懂，当作空的：$e');
      return {};
    }
  }

  void _write(Map<String, String> map) {
    cacheDir.createSync(recursive: true);
    _index.writeAsStringSync(jsonEncode(map));
  }

  /// 这张图对应的 OSS key；没传过就传一次。
  ///
  /// 传不上去时抛异常——**不能悄悄退回文字搜**：人点的是「画面相似」，
  /// 给他一批按文字搜出来的东西，他不会知道自己看的根本不是相似画面
  Future<String> keyFor(File image) async {
    if (!image.existsSync()) {
      throw StateError('这一帧不在本地，没法拿去搜：${image.path}');
    }
    final digest = sha256.convert(await image.readAsBytes()).toString();
    final cached = _read()[digest];
    if (cached != null && cached.isNotEmpty) return cached;

    final out = await gateway.text([
      'content',
      'upload',
      '--type',
      'image',
      '--folder',
      '$folderId',
      image.path,
    ], what: '上传查询帧');
    final key = _ossIdOf(out);
    if (key == null || key.isEmpty) {
      throw StateError('上传查询帧之后没拿到 ossId，搜不了相似画面。返回：$out');
    }
    _write({..._read(), digest: key});
    return key;
  }

  /// 上传返回里的 `ossId` 就是 `--like-image` 要的那个 key
  static String? _ossIdOf(String stdout) {
    try {
      final raw = jsonDecode(stdout);
      if (raw is Map && raw['ossId'] is String) return raw['ossId'] as String;
    } catch (_) {
      // 落到下面按文本捞
    }
    final m = RegExp(r'"ossId"\s*:\s*"([^"]+)"').firstMatch(stdout);
    return m?.group(1);
  }
}
