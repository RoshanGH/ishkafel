import '../../core/ffmpeg/process_runner.dart' show FfmpegException;
import '../../core/log/app_log.dart';
import '../../core/miaoa/miaoa_tag_service.dart';

/// 标签名 → miaoa 标签 id 的解析器。
///
/// **为什么需要它**：打标产出落在 `Shot.tags`/`SemanticUnit.tags` 上的是标签
/// **名**（受控词表就是名字），而 miaoa 的 `content search --public-tag` 只收
/// 标签 **id**。两者之间必须有一次映射，映射表来自任务选定的标签组。
///
/// **按组存，不合并成一张扁平表**：同一个标签名可以同时存在于好几个标签组里，
/// 而 id 是**按组分配**的。合并成一张表就只剩「先来的那个 id」，检索时就会拿着
/// 另一个组的同名标签去搜——搜出来的素材看着沾边，其实压根不是这个维度的。
///
/// 整组标签一次拉取后缓存：一次会话里用户会在几十个镜头之间来回切，每次都拉
/// 一遍既慢又没必要。拉取失败不抛——候选面板据此把标签检索标为不可用并**说明
/// 原因**。
class TagIdResolver {
  final MiaoaTagService service;

  TagIdResolver(this.service);

  /// 标签组 id →（标签名 → 标签 id）
  Map<int, Map<String, int>> _byGroup = const {};
  String? _loadFailure;
  bool _loaded = false;

  /// 已成功拉取过映射表
  bool get loaded => _loaded;

  /// 拉取失败的中文原因（成功或未拉取时为 null）
  String? get loadFailure => _loadFailure;

  /// 拉取若干标签组的标签表。重复调用只在未成功时重试。
  ///
  /// 一个层可以选多个标签组，打标产出的标签名散落在各组里，只解析第一个组
  /// 会让其余组的标签统统查不到 id，检索键悄悄缺一半。
  Future<void> loadAll(Iterable<int> groupIds) async {
    if (_loaded || groupIds.isEmpty) return;
    final byGroup = <int, Map<String, int>>{};
    String? failure;
    for (final id in groupIds) {
      try {
        byGroup[id] = {
          for (final t in await service.listTags(id)) t.name: t.id,
        };
      } catch (e) {
        // 单个组拉失败不牵连其余组；全都失败时才对外报错
        AppLog.warn('阶段②标签表拉取失败（groupId=$id）：$e');
        failure ??= '无法读取标签组，暂时不能按标签检索，请稍后重试';
      }
    }
    if (byGroup.isEmpty && failure != null) {
      _loadFailure = failure;
      return;
    }
    _byGroup = Map.unmodifiable(byGroup);
    _loaded = true;
    _loadFailure = null;
  }

  /// 单组快捷方式（保留给只关心一个组的调用方）
  Future<void> load(int groupId) async {
    if (_loaded) return;
    try {
      final tags = await service.listTags(groupId);
      _byGroup = Map.unmodifiable({
        groupId: {for (final t in tags) t.name: t.id},
      });
      _loaded = true;
      _loadFailure = null;
    } on MiaoaException catch (e) {
      // 服务层已给出中文，原样带出，不再包壳
      _loadFailure = '无法读取标签组，暂时不能按标签检索：${e.message}';
      AppLog.warn('阶段②标签表拉取失败（groupId=$groupId）：${e.message}');
    } on FfmpegException catch (e) {
      _loadFailure = e.message;
      AppLog.warn('阶段②标签表拉取失败（groupId=$groupId）：${e.message}');
    } catch (e) {
      _loadFailure = '无法读取标签组，暂时不能按标签检索，请稍后重试';
      AppLog.warn('阶段②标签表拉取出现未预期异常（groupId=$groupId）：$e');
    }
  }

  /// 在**指定的那一个标签组**里解析这个标签名；这个组里没有就返回 null。
  ///
  /// 打标是分维度进行的（一个标签组 = 一个维度），所以每个标签本来就知道自己
  /// 出自哪个组。检索时就该拿那个组里的那个 id。
  int? idIn(String name, int groupId) => _byGroup[groupId]?[name];

  /// 在给定的这几个组里按顺序找。给不出组归属的旧数据才走这条路。
  int? idAmong(String name, Iterable<int> groupIds) {
    for (final id in groupIds) {
      final hit = _byGroup[id]?[name];
      if (hit != null) return hit;
    }
    return null;
  }

  /// 把标签名解析成 id；解析不到的名字（已改名/已删除）跳过，不冒充成 0。
  /// [groupIds] 限定在这几个组里找（这一层选的那几个组）。
  List<int> idsOf(Iterable<String> names, {Iterable<int>? groupIds}) {
    final scope = groupIds ?? _byGroup.keys;
    return [
      for (final name in names) ?idAmong(name, scope),
    ];
  }
}
