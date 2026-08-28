import 'dart:convert';

import '../log/app_log.dart';
import 'miaoa_exception.dart';
import 'miaoa_gateway.dart';

/// 候选素材（miaoa 分镜库的一条记录）
///
/// 只保留阶段②选材真正要用的字段：卡片展示、检索复用、以及后续合成需要的
/// 播放地址。miaoa 返回的字段有三十多个，其余与本产品无关。
class CandidateMaterial {
  final int id;
  final String name;

  /// 这条素材属于哪个项目。
  ///
  /// 替换裂变的意义就是换掉原来那批画面，而语义搜越准、搜出来越是原项目拍的
  /// （跟原镜最像的当然是原片自己的素材）。要「换成别的项目拍的」就得认得出
  /// 它是哪个项目的。旧数据里可能没有这个字段，所以可空
  final int? projectId;

  /// 画面描述（AI 生成，也是「画面描述语义搜」的检索维度）
  final String sceneDescription;

  /// 这条分镜的旁白/台词（miaoa 的 `voiceover`）。
  ///
  /// 整体替换换的是「一句台词对应的一段画面」，用户先要看的就是这条素材
  /// 原本在说什么——只给缩略图，他得一条条点开听。
  final String voiceover;

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
    this.projectId,
    required this.sceneDescription,
    this.voiceover = '',
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
      projectId: raw['projectId'] is int ? raw['projectId'] as int : null,
      sceneDescription:
          raw['sceneDescription'] is String ? raw['sceneDescription'] as String : '',
      voiceover: raw['voiceover'] is String ? raw['voiceover'] as String : '',
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
/// - 文件名：`--keyword X --by name`（兜底：知道有那条片子，直接按名字捞）
/// - 以图搜图：`--like-image <fileKey>`
///
/// 全部限定 `--type storyboard`：本产品替换的是**视觉镜头**，对应 miaoa 的
/// 分镜库；成片库（`--type video`）是整条片子，不是替换素材。
class MiaoaContentService {
  final MiaoaGateway gateway;

  MiaoaContentService({MiaoaGateway? gateway})
      : gateway = gateway ?? MiaoaGateway();

  /// 按标签检索。[mode] 为 `and`（全部满足）或 `or`（任一满足）；
  /// [projectIds] 为空表示不限项目（我的全部项目聚合）
  Future<CandidatePage> searchByTags({
    required List<int> tagIds,
    String mode = 'or',
    List<int> projectIds = const [],
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
      ..._projects(projectIds),
      ..._paging(page, pageSize),
    ]);
  }

  /// 按画面描述语义检索。[tagIds] 是可叠加的标签约束（所有维度通用）
  Future<CandidatePage> searchByDescription({
    required String keyword,
    List<int> tagIds = const [],
    List<int> projectIds = const [],
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
      ..._tagFilter(tagIds),
      ..._projects(projectIds),
      ..._paging(page, pageSize),
    ]);
  }

  /// 按**文件名**检索（CLI 的默认维度 `--by name`）。
  ///
  /// 这是**兜底路子**：主路径是拿参考镜头的画面描述/标签去找像的画面，
  /// 筛不到时人会说「我知道妙啊里有那条片子」，直接按名字捞出来。
  /// 所以调用方切到这个维度时会顺手把标签约束摘掉——都到按名字找了，
  /// 还挂着标签只会继续搜不到
  Future<CandidatePage> searchByName({
    required String keyword,
    List<int> tagIds = const [],
    List<int> projectIds = const [],
    int page = 1,
    int pageSize = 20,
  }) async {
    if (keyword.trim().isEmpty) {
      throw MiaoaException('名称为空，无法检索候选素材');
    }
    return await _search([
      '--keyword',
      keyword.trim(),
      '--by',
      'name',
      ..._tagFilter(tagIds),
      ..._projects(projectIds),
      ..._paging(page, pageSize),
    ]);
  }

  /// 按台词（旁白）语义检索——参考片这一句在说什么，就找说同类话的分镜
  Future<CandidatePage> searchByVoiceover({
    required String keyword,
    List<int> tagIds = const [],
    List<int> projectIds = const [],
    int page = 1,
    int pageSize = 20,
  }) async {
    if (keyword.trim().isEmpty) {
      throw MiaoaException('台词为空，无法检索候选素材');
    }
    return await _search([
      '--keyword',
      keyword.trim(),
      '--by',
      'voiceover',
      ..._tagFilter(tagIds),
      ..._projects(projectIds),
      ..._paging(page, pageSize),
    ]);
  }

  /// 首帧以图搜图。[fileKey] 是 OSS key，不是 URL
  Future<CandidatePage> searchByImage({
    required String fileKey,
    List<int> tagIds = const [],
    List<int> projectIds = const [],
    int page = 1,
    int pageSize = 20,
  }) async {
    if (fileKey.trim().isEmpty) {
      throw MiaoaException('缺少查询帧，无法以图搜图');
    }
    return await _search([
      '--like-image',
      fileKey.trim(),
      ..._tagFilter(tagIds),
      ..._projects(projectIds),
      ..._paging(page, pageSize),
    ]);
  }

  /// 标签约束（任一满足）。空列表整个不传——空约束不该发给服务端
  static List<String> _tagFilter(List<int> tagIds) => tagIds.isEmpty
      ? const []
      : ['--public-tag', tagIds.join(','), '--public-mode', 'or'];

  /// 这个项目里一共有多少条分镜。
  ///
  /// 判断一个标签「有没有区分度」要拿它的命中数和这个总数比——「实拍」在
  /// 6012 条的项目里命中 5437 条（90%），用了等于没筛；同一个数字在 788 条
  /// 的项目里就是完全正常的检索键。没有分母就只能拿标签之间互相比，
  /// 小项目里必然误判（见 [narrowTagQuery]）。
  Future<int> countAll({List<int> projectIds = const []}) async {
    final page = await _search([
      ..._projects(projectIds),
      ..._paging(1, 1),
    ]);
    return page.total;
  }

  /// 空列表就整个不传 `--projects`：CLI 把「不传」解释成我的全部项目聚合，
  /// 而传一个空串会被当成非法值
  static List<String> _projects(List<int> ids) =>
      ids.isEmpty ? const [] : ['--projects', ids.join(',')];

  /// 按 id 取单条素材（导出时要拿它的播放地址）。
  ///
  /// 一条一次调用：`content search --ids` 服务端目前直接 500（真机实测），
  /// 不能拿它当批量入口。找不到返回 null，由调用方决定是跳过还是报错。
  ///
  /// id 一律搁在 `--` 后面：素材库里真有负数 id（真机遇到 -19954），
  /// 直接当位置参数传会被命令行解析成参数名，报
  /// `unexpected argument '-1' found`，这一条就静静地落不了地
  Future<CandidateMaterial?> fetchById(int id) async {
    final stdout = await gateway.text([
      'content',
      'get',
      '--type',
      'storyboard',
      '--json',
      '--',
      '$id',
    ], what: '读取素材详情');
    return CandidateMaterial.tryFromJson(_decode(stdout));
  }

  static List<String> _paging(int page, int pageSize) => [
        '--page',
        '$page',
        '--page-size',
        '$pageSize',
      ];

  Future<CandidatePage> _search(List<String> extraArgs) async {
    final stdout = await gateway.text([
      'content',
      'search',
      '--type',
      'storyboard',
      ...extraArgs,
      '--json',
    ], what: '素材库检索');
    final decoded = _decode(stdout);
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

  static Map<String, dynamic> _decode(String stdout) {
    try {
      final decoded = jsonDecode(stdout);
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException catch (e) {
      AppLog.warn('候选素材检索返回非 JSON：$e');
    }
    throw MiaoaException('素材库返回的数据格式无法识别，请稍后重试');
  }
}
