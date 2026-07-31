import 'dart:convert';

import '../ffmpeg/process_runner.dart';
import '../log/app_log.dart';
import 'miaoa_tag_service.dart' show MiaoaException;

/// 候选素材（miaoa 分镜库的一条记录）
///
/// 只保留阶段②选材真正要用的字段：卡片展示、检索复用、以及后续合成需要的
/// 播放地址。miaoa 返回的字段有三十多个，其余与本产品无关。
class CandidateMaterial {
  final int id;
  final String name;

  /// 画面描述（AI 生成，也是「画面描述语义搜」的检索维度）
  final String sceneDescription;

  /// 首帧缩略图地址（候选卡封面；同时是「首帧以图搜图」的查询帧来源）
  final String? thumbnailUrl;

  /// 预览播放地址（签名 URL，有时效）
  final String? previewUrl;

  /// OSS key，以图搜图要用它而不是 URL
  final String? fileKey;

  /// 标签名（公共标签 + AI 标签合并去重，供候选卡展示与人工核对）
  final List<String> tags;

  const CandidateMaterial({
    required this.id,
    required this.name,
    required this.sceneDescription,
    required this.thumbnailUrl,
    required this.previewUrl,
    required this.fileKey,
    required this.tags,
  });

  /// 宽松解析：任何一个字段畸形都只让**这一条**候选被跳过，不牵连整批
  /// （miaoa 的返回是外部数据，不可信）
  static CandidateMaterial? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! int) return null;
    final media = raw['mediaFile'];
    final mediaMap = media is Map ? media : const {};
    return CandidateMaterial(
      id: id,
      name: raw['name'] is String ? raw['name'] as String : '未命名素材',
      sceneDescription:
          raw['sceneDescription'] is String ? raw['sceneDescription'] as String : '',
      thumbnailUrl: _stringOrNull(mediaMap['thumbnailUrl']),
      previewUrl: _stringOrNull(mediaMap['previewUrl']),
      fileKey: _stringOrNull(mediaMap['fileKey']),
      tags: _tagNames(raw),
    );
  }

  static String? _stringOrNull(Object? v) =>
      v is String && v.isNotEmpty ? v : null;

  /// 公共标签与 AI 标签合并去重，保持原有顺序（公共标签在前，人工确认过的更可信）
  static List<String> _tagNames(Map<dynamic, dynamic> raw) {
    final names = <String>[];
    for (final key in const ['publicTags', 'aiTags']) {
      final list = raw[key];
      if (list is! List) continue;
      for (final item in list) {
        if (item is! Map) continue;
        final name = item['name'];
        if (name is String && name.isNotEmpty && !names.contains(name)) {
          names.add(name);
        }
      }
    }
    return List.unmodifiable(names);
  }
}

/// 一页检索结果
class CandidatePage {
  final List<CandidateMaterial> items;

  /// 命中总数（用于「共 N 条」与翻页）
  final int total;

  /// 因畸形而被跳过的条目数：不静默丢弃，让上层能如实告知用户
  final int skipped;

  CandidatePage({
    required List<CandidateMaterial> items,
    required this.total,
    required this.skipped,
  }) : items = List.unmodifiable(items);
}

/// 候选素材检索的三种互斥模式（产品决策：两层通用，单次只能选一种）
enum CandidateSearchMode {
  /// 标签精确筛（受控词表；打标产出的标签就是这里的检索键）
  tag,

  /// 画面描述语义搜
  description,

  /// 首帧以图搜图
  image,
}

/// miaoa 候选素材检索（走 miaoa CLI 子进程）
///
/// 三种模式对应 CLI 的三组参数：
/// - 标签：`--public-tag <id,...> --public-mode and|or`
/// - 画面描述：`--keyword X --by content`
/// - 以图搜图：`--like-image <fileKey>`
///
/// 全部限定 `--type storyboard`：本产品替换的是**视觉镜头**，对应 miaoa 的
/// 分镜库；成片库（`--type video`）是整条片子，不是替换素材。
class MiaoaContentService {
  final ProcessRunner run;
  final String binary;

  MiaoaContentService({this.run = systemProcessRunner, this.binary = 'miaoa'});

  /// 按标签检索。[mode] 为 `and`（全部满足）或 `or`（任一满足）
  Future<CandidatePage> searchByTags({
    required List<int> tagIds,
    String mode = 'or',
    int page = 1,
    int pageSize = 20,
  }) async {
    if (tagIds.isEmpty) {
      throw MiaoaException('未选择任何标签，无法检索候选素材');
    }
    return await _search([
      '--public-tag',
      tagIds.join(','),
      '--public-mode',
      mode,
      ..._paging(page, pageSize),
    ]);
  }

  /// 按画面描述语义检索
  Future<CandidatePage> searchByDescription({
    required String keyword,
    int page = 1,
    int pageSize = 20,
  }) async {
    if (keyword.trim().isEmpty) {
      throw MiaoaException('画面描述为空，无法检索候选素材');
    }
    return await _search([
      '--keyword',
      keyword.trim(),
      '--by',
      'content',
      ..._paging(page, pageSize),
    ]);
  }

  /// 首帧以图搜图。[fileKey] 是 OSS key，不是 URL
  Future<CandidatePage> searchByImage({
    required String fileKey,
    int page = 1,
    int pageSize = 20,
  }) async {
    if (fileKey.trim().isEmpty) {
      throw MiaoaException('缺少查询帧，无法以图搜图');
    }
    return await _search([
      '--like-image',
      fileKey.trim(),
      ..._paging(page, pageSize),
    ]);
  }

  static List<String> _paging(int page, int pageSize) => [
        '--page',
        '$page',
        '--page-size',
        '$pageSize',
      ];

  Future<CandidatePage> _search(List<String> extraArgs) async {
    final args = [
      'content',
      'search',
      '--type',
      'storyboard',
      ...extraArgs,
      '--json',
    ];
    final result = await run(binary, args);

    if (result.exitCode != 0) {
      throw MiaoaException(_friendlyError(result.exitCode, _text(result.stderr)));
    }

    final decoded = _decode(_text(result.stdout));
    final records = decoded['records'];
    if (records is! List) {
      throw MiaoaException('素材库返回的数据格式无法识别，请稍后重试');
    }

    final items = <CandidateMaterial>[];
    var skipped = 0;
    for (final raw in records) {
      final item = CandidateMaterial.tryFromJson(raw);
      if (item == null) {
        skipped++;
        continue;
      }
      items.add(item);
    }
    if (skipped > 0) {
      AppLog.warn('候选素材检索：跳过 $skipped 条无法解析的记录');
    }

    final total = decoded['total'];
    return CandidatePage(
      items: items,
      total: total is int ? total : items.length,
      skipped: skipped,
    );
  }

  /// 子进程输出既可能是 String，也可能是 `List<int>`（取决于 stdoutEncoding）
  static String _text(Object? out) {
    if (out is String) return out;
    if (out is List<int>) return utf8.decode(out, allowMalformed: true);
    return '';
  }

  static Map<String, dynamic> _decode(String stdout) {
    try {
      final decoded = jsonDecode(stdout);
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException catch (e) {
      AppLog.warn('候选素材检索返回非 JSON：$e');
    }
    throw MiaoaException('素材库返回的数据格式无法识别，请稍后重试');
  }

  /// 把 CLI 的退出码与 stderr 翻译成用户能照做的中文提示
  static String _friendlyError(int exitCode, String stderr) {
    final lower = stderr.toLowerCase();
    if (lower.contains('401') || lower.contains('unauthorized')) {
      return '素材库登录已失效，请在终端执行 miaoa auth login 后重试';
    }
    if (lower.contains('403') || lower.contains('forbidden')) {
      return '没有访问该素材库的权限，请联系素材库管理员';
    }
    if (lower.contains('not found') || lower.contains('no such file')) {
      return '未检测到 miaoa 命令行工具，请先安装后重试';
    }
    if (lower.contains('timed out') || lower.contains('timeout')) {
      return '连接素材库超时，请检查网络后重试';
    }
    AppLog.warn('miaoa 检索失败（exit=$exitCode）：$stderr');
    return '素材库检索失败，请稍后重试';
  }
}
