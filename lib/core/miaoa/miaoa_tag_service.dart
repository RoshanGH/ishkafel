import 'dart:convert';
import '../log/app_log.dart';
import 'miaoa_exception.dart';
import 'miaoa_gateway.dart';

// 老调用方都是从这里 show MiaoaException 的，转发一份保持导入路径不变
export 'miaoa_exception.dart' show MiaoaException;

/// 标签组（对应 miaoa tag group list 输出）
class TagGroup {
  final int id;
  final String name;
  final String materialType;
  final String tagType;

  /// 组内标签名。拉取时带 `--include-tags` 一次取回——127 个组、2461 个
  /// 标签合计只有约 210KB，一次拿全比「选中后再拉一次」更省事，也让
  /// 「按标签名搜组」成为可能（用户往往记得住标签、记不住它在哪个组）。
  final List<String> tags;

  const TagGroup({
    required this.id,
    required this.name,
    required this.materialType,
    required this.tagType,
    this.tags = const [],
  });

  /// 组内标签名；字段缺失（未带 --include-tags）或个别条目非法都只当没有，
  /// 不因为标签解析失败而丢掉整个标签组
  static List<String> _tagNames(Object? raw) {
    if (raw is! List) return const [];
    return List.unmodifiable([
      for (final t in raw)
        if (t is Map && t['tagName'] is String) t['tagName'] as String,
    ]);
  }

  /// 宽松解析：任一字段缺失或类型不符都返回 null，由调用方跳过并汇总。
  ///
  /// 四个字段一律从严——materialType 决定标签组用在图片还是视频上，
  /// 缺省成空串会导致后续按类型筛选悄悄筛错，宁可这条不要。
  static TagGroup? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['groupName'];
    final materialType = raw['materialType'];
    final tagType = raw['tagType'];
    if (id is! int || name is! String) return null;
    if (materialType is! String || tagType is! String) return null;
    return TagGroup(
      id: id,
      name: name,
      materialType: materialType,
      tagType: tagType,
      tags: _tagNames(raw['tags']),
    );
  }
}

/// 标签（对应 miaoa tag list 输出）
class TagInfo {
  final int id;
  final String name;

  const TagInfo({required this.id, required this.name});

  /// 宽松解析：字段缺失或类型不符返回 null，由调用方跳过并汇总
  static TagInfo? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['tagName'];
    if (id is! int || name is! String) return null;
    return TagInfo(id: id, name: name);
  }
}

/// miaoa 标签体系拉取（标签组、标签，均为只读子进程调用）
class MiaoaTagService {
  final MiaoaGateway gateway;

  MiaoaTagService({MiaoaGateway? gateway}) : gateway = gateway ?? MiaoaGateway();

  static const _groupAction = 'tag group list';
  static const _tagAction = 'tag list';

  Future<List<TagGroup>> listGroups() async {
    // --include-tags：一次把组内标签也带回来。多出的约 200KB 换掉了
    // 「每选一个组再拉一次标签」的往返，也让搜索能匹配标签名
    final stdout = await gateway.text(
        ['tag', 'group', 'list', '--scope', 'tenant', '--include-tags', '--json'],
        what: '读取标签组');
    final raw = _decodeList(stdout, _groupAction);
    return _parseEntries(raw, TagGroup.tryFromJson, _groupAction);
  }

  Future<List<TagInfo>> listTags(int groupId) async {
    final stdout = await gateway
        .text(['tag', 'list', '--group', '$groupId', '--json'], what: '读取标签');
    final raw = _decodeList(stdout, _tagAction);
    return _parseEntries(raw, TagInfo.tryFromJson, _tagAction);
  }

  /// 逐条宽松解析：非法条目跳过并汇总；全部非法则报错，不静默返回空列表
  static List<T> _parseEntries<T>(
      List<Object?> raw, T? Function(Object?) parse, String action) {
    final items = <T>[];
    var skipped = 0;
    for (final entry in raw) {
      final item = parse(entry);
      if (item == null) {
        skipped++;
        continue;
      }
      items.add(item);
    }
    if (skipped > 0) {
      AppLog.warn('miaoa $action 返回的 $skipped 条记录字段缺失或类型不符，已跳过');
    }
    if (items.isEmpty && skipped > 0) {
      throw MiaoaException('miaoa $action 返回的 $skipped 条记录全部格式异常，无法解析标签');
    }
    return List.unmodifiable(items);
  }

  /// CLI 输出是不可信输入：JSON 合法性、顶层结构逐级校验，
  /// 一律转成中文 [MiaoaException]，不让 TypeError 原文穿透到用户面前。
  /// （退出码与「起不来」已由 [MiaoaGateway] 挡掉并分类）
  List<Object?> _decodeList(String stdout, String action) {
    final Object? decoded;
    try {
      decoded = jsonDecode(stdout);
    } on FormatException catch (e) {
      throw MiaoaException('miaoa $action 返回非法 JSON：${e.message}');
    }
    if (decoded is! List) {
      throw MiaoaException('miaoa $action 返回的不是数组，无法解析标签列表');
    }
    return decoded;
  }
}
