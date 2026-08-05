import 'dart:convert';

import '../ffmpeg/process_runner.dart';
import '../log/app_log.dart';
import '../miaoa/miaoa_tag_service.dart' show MiaoaException;
import '../miaoa/miaoa_errors.dart';
import 'bgm_plan.dart';

/// miaoa 音频库检索（走 miaoa CLI 子进程）。
///
/// 与候选素材检索分开一个类，是因为两者除了「都调 content search」以外没有
/// 共同点：这边是 `--type audio`、结果按时长与情绪挑，那边是
/// `--type storyboard`、结果要做规格探测与时长差比对。硬塞进一个类只会让
/// 两边的参数互相污染——打成 storyboard 会返回一堆画面素材，用户拿去当 BGM
/// 一首都放不出来。
/// 一页检索结果，外加「这页是怎么来的」。
class BgmSearchPage {
  final List<BgmMaterial> items;

  /// 本项目下一条音频都没有，已放开到全库。界面据此给一行说明——否则用户
  /// 会以为这些曲子就是本项目的。
  final bool widenedFromProject;

  const BgmSearchPage({required this.items, this.widenedFromProject = false});
}

class BgmLibrary {
  final ProcessRunner run;
  final String binary;

  BgmLibrary({this.run = systemProcessRunner, this.binary = 'miaoa'});

  /// 检索音频素材。[keyword] 为空（或只有空白）时列出音频库里的内容。
  ///
  /// **项目条件是软的**：音频库并不按成片所属项目归档——真机上拿滴露的项目
  /// 去筛，`total` 直接是 0，而不带项目能列出一堆可用的曲子。硬筛的结果就是
  /// 用户一打开「选配乐」看到一片空白，还以为是 CLI 坏了。所以先按项目找，
  /// 项目内一条都没有就自动放开到全库，并让界面把这件事说清楚
  /// （[BgmSearchPage.widenedFromProject]）。
  ///
  /// 画面素材那边不这么做——分镜库确实按项目归档，筛出来是有东西的。
  Future<BgmSearchPage> search({
    String? keyword,
    List<int> projectIds = const [],
    int page = 1,
    int pageSize = 30,
  }) async {
    final scoped = await _searchOnce(
        keyword: keyword,
        projectIds: projectIds,
        page: page,
        pageSize: pageSize);
    if (projectIds.isEmpty || scoped.isNotEmpty) {
      return BgmSearchPage(items: scoped);
    }

    final all = await _searchOnce(
        keyword: keyword, projectIds: const [], page: page, pageSize: pageSize);
    // 全库也空，那就是真没搜到；这时说「已放开」只会误导
    return BgmSearchPage(items: all, widenedFromProject: all.isNotEmpty);
  }

  Future<List<BgmMaterial>> _searchOnce({
    required String? keyword,
    required List<int> projectIds,
    required int page,
    required int pageSize,
  }) async {
    final trimmed = keyword?.trim() ?? '';
    final result = await run(binary, [
      'content',
      'search',
      '--type',
      'audio',
      if (trimmed.isNotEmpty) ...['--keyword', trimmed],
      // 空列表整个不传：CLI 把「不传」解释成我的全部项目聚合
      if (projectIds.isNotEmpty) ...['--projects', projectIds.join(',')],
      '--page',
      '$page',
      '--page-size',
      '$pageSize',
      '--json',
    ]);

    if (result.exitCode != 0) {
      throw MiaoaException(miaoaFriendlyError(result.exitCode,
          miaoaErrorText(_text(result.stdout), _text(result.stderr))));
    }

    final decoded = _decode(_text(result.stdout));
    final records = decoded['records'];
    if (records is! List) {
      throw MiaoaException('音频库返回的数据格式无法识别，请稍后重试');
    }

    final items = <BgmMaterial>[];
    var skipped = 0;
    for (final raw in records) {
      final item = _parse(raw);
      if (item == null) {
        skipped++;
        continue;
      }
      items.add(item);
    }
    if (skipped > 0) AppLog.warn('音频库检索：跳过 $skipped 条无法解析的记录');
    return List.unmodifiable(items);
  }

  /// 解析一条音频记录。
  ///
  /// 缺时长的**照收**，只标成 0（界面上写「时长未知」）：整条丢掉的话，
  /// 用户在库里看不到这首歌却又搜得到，比一个「时长未知」更困惑。
  /// 缺 id 才丢——没有 id 就没法落进方案里。
  static BgmMaterial? _parse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! int) return null;
    final media = raw['mediaFile'];
    final mediaMap = media is Map ? media : const {};
    // duration 已经是毫秒：真机核对过，它与同一条记录 asrText 里的
    // utterance 时间戳同一量纲（16561 对应 16.5 秒的语音）。当成秒会显示成
    // 四个多小时，「裁还是循环」的判断也全反了。
    final duration = mediaMap['duration'];
    return BgmMaterial(
      id: id,
      name: raw['name'] is String ? raw['name'] as String : '未命名音频',
      durationMs: duration is num ? duration.round() : 0,
      previewUrl: mediaMap['previewUrl'] is String
          ? mediaMap['previewUrl'] as String
          : null,
      tags: _mergeTags(raw),
      hasSpeech: _hasSpeech(raw['asrText']),
    );
  }

  /// 三处标签合并去重：公共标签、AI 标签、个人标签。没有 `tagNames` 这个
  /// 字段——按它取只会永远拿到空列表。
  static List<String> _mergeTags(Map<dynamic, dynamic> raw) {
    final merged = <String>[];
    for (final key in const ['publicTags', 'aiTags', 'personalTags']) {
      final list = raw[key];
      if (list is! List) continue;
      for (final t in list.whereType<String>()) {
        if (!merged.contains(t)) merged.add(t);
      }
    }
    return List.unmodifiable(merged);
  }

  /// 这条音频里有没有人说话。
  ///
  /// 要标出来是因为：把一条带解说的音频压在成片下面当 BGM，会和原片的
  /// 口播直接打架，用户听一遍才发现就太晚了。asrText 是素材库转写出来的
  /// 结果，有内容就说明有人声。
  static bool _hasSpeech(Object? asrText) {
    if (asrText is! String || asrText.trim().isEmpty) return false;
    try {
      final decoded = jsonDecode(asrText);
      if (decoded is Map) {
        final text = decoded['text'];
        return text is String && text.trim().isNotEmpty;
      }
    } catch (_) {
      // 不是 JSON 就按纯文本看待
    }
    return asrText.trim() != 'null';
  }

  static String _text(Object? out) {
    if (out is String) return out;
    if (out is List<int>) return utf8.decode(out, allowMalformed: true);
    return '';
  }

  static Map<String, dynamic> _decode(String stdout) {
    try {
      final decoded = jsonDecode(stdout);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (e) {
      AppLog.warn('音频库返回无法解析为 JSON：$e');
    }
    throw MiaoaException('音频库返回的数据格式无法识别，请稍后重试');
  }
}
