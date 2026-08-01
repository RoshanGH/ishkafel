import '../../core/ffmpeg/process_runner.dart' show FfmpegException;
import '../../core/log/app_log.dart';
import '../../core/miaoa/miaoa_tag_service.dart';

/// 标签名 → miaoa 标签 id 的解析器。
///
/// **为什么需要它**：打标产出落在 `Shot.tags` 上的是标签**名**（受控词表就是
/// 名字），而 miaoa 的 `content search --public-tag` 只收标签 **id**。两者之间
/// 必须有一次映射，映射表来自任务选定的视觉镜头标签组。
///
/// 整组标签一次拉取后缓存：一次会话里用户会在几十个镜头之间来回切，每次都拉
/// 一遍既慢又没必要。拉取失败不抛——候选面板据此把标签检索标为不可用并**说明
/// 原因**，画面描述检索照常可用。
class TagIdResolver {
  final MiaoaTagService service;

  TagIdResolver(this.service);

  Map<String, int> _byName = const {};
  String? _loadFailure;
  bool _loaded = false;

  /// 已成功拉取过映射表
  bool get loaded => _loaded;

  /// 拉取失败的中文原因（成功或未拉取时为 null）
  String? get loadFailure => _loadFailure;

  /// 拉取若干标签组的标签表并合并。重复调用只在未成功时重试。
  ///
  /// 合并是必须的：一个层可以选多个标签组，打标产出的标签名散落在各组里，
  /// 只解析第一个组会让其余组的标签统统查不到 id，检索键悄悄缺一半。
  Future<void> loadAll(Iterable<int> groupIds) async {
    if (_loaded || groupIds.isEmpty) return;
    final merged = <String, int>{};
    String? failure;
    for (final id in groupIds) {
      try {
        for (final t in await service.listTags(id)) {
          merged.putIfAbsent(t.name, () => t.id);
        }
      } catch (e) {
        // 单个组拉失败不牵连其余组；全都失败时才对外报错
        AppLog.warn('阶段②标签表拉取失败（groupId=$id）：$e');
        failure ??= '无法读取标签组，暂时不能按标签检索，请稍后重试';
      }
    }
    if (merged.isEmpty && failure != null) {
      _loadFailure = failure;
      return;
    }
    _byName = Map.unmodifiable(merged);
    _loaded = true;
    _loadFailure = null;
  }

  /// 单组快捷方式（保留给只关心一个组的调用方）
  Future<void> load(int groupId) async {
    if (_loaded) return;
    try {
      final tags = await service.listTags(groupId);
      _byName = Map.unmodifiable({for (final t in tags) t.name: t.id});
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

  /// 把标签名解析成 id；解析不到的名字（已改名/已删除）跳过，不冒充成 0
  List<int> idsOf(Iterable<String> names) => [
        for (final name in names)
          if (_byName[name] != null) _byName[name]!,
      ];
}
