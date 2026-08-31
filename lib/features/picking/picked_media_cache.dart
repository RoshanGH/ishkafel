import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/log/app_log.dart';

/// 一条已选素材的本体在本地的状态
enum PickedMediaStatus {
  /// 还没开始下
  absent,

  /// 正在下
  downloading,

  /// 已经躺在本地，素材库那边怎么变都不影响这条任务
  ready,

  /// 下不下来。原因见 [PickedMediaCache.failureOf]
  failed,
}

/// 把「已经挑中的素材」的**视频本体**固定在本地。
///
/// **为什么勾选就要下载**：方案里存的只是素材 id，真正要用它是在预览合成和
/// 导出的时候。这中间可能隔着几个小时——别人在素材库那边把这条素材删了、
/// 换了、或者签名地址过期了，到导出那一刻才发现就太晚了。用户原话：
/// 「万一我在执行导出的时候，其他人在妙啊的系统上执行把这些素材删掉，
/// 我就很尴尬了」。这是专业剪辑软件的通行做法（FCP/Premiere 的 media
/// management、剪映把素材加进时间轴就落本地）。
///
/// **为什么取消勾选不立刻删**：取消勾选往往是试错动作——先取消、比一比、
/// 又改回来。立刻删意味着改回来就得重下几十兆。取消只解除固定，文件留在
/// 缓存池里；真正的删除交给 [sweep] 的配额回收（超上限时淘汰**未固定**的、
/// 最久没被碰过的那些）。
///
/// 下载动作复用导出那一套（[MaterialDownloader.fetch]）：同一个缓存目录、
/// 同一份按 id 的去重，导出时不必再下一遍。
class PickedMediaCache extends ChangeNotifier {
  /// 按 id 取素材到本地，返回本地路径。失败抛异常
  final Future<String> Function(int candidateId) fetch;

  /// 缓存目录，[sweep] 要按它算总量
  final Directory cacheDir;

  /// 同时下几条。素材是几十兆的视频，开太多只会互相抢带宽
  final int concurrency;

  /// 缓存上限（字节）。超了就按最久未用淘汰未固定的
  final int quotaBytes;

  /// 缓存文件的扩展名（画面素材 `mp4`、配乐 `mp3`）。
  /// 多轨播放要直接把本地路径喂给播放器，得知道文件叫什么
  final String extension;

  /// 每条素材**最终可播的**本地路径。可能不是 `<id>.<ext>`——素材规格与原片
  /// 不一致时会先规格化一次（见 [MaterialNormalizer]），产物在别处
  final Map<int, String> _paths = {};
  final Map<int, PickedMediaStatus> _status = {};
  final Map<int, String> _failure = {};
  final Set<int> _pinned = {};
  final List<int> _queue = [];
  int _running = 0;
  bool _disposed = false;

  PickedMediaCache({
    required this.fetch,
    required this.cacheDir,
    // **同时下几条**。素材是几兆的小片子，两条两条地下，一条脚本几十条
    // 素材要等很久——人刚铺完片想点开看一眼，得到的是「素材还没下载好」。
    // 它们之间没有任何依赖，本来就该一起下
    this.concurrency = 6,
    this.quotaBytes = 10 * 1024 * 1024 * 1024,
    this.extension = 'mp4',
  });

  /// 这条素材在本地的路径；还没下下来（或下了个空文件）时返回 null。
  ///
  /// 多轨播放直接播本地文件，所以「在不在本地」就是「这一段能不能播」——
  /// 取不到时上层把这一段当没选，播原片，而不是播一个空洞。
  String? localPathOf(int id) {
    final resolved = _paths[id];
    if (resolved != null && File(resolved).existsSync()) return resolved;
    // 这一轮还没取过（比如刚重开 app，固定还在排队）：退回约定路径。
    // 规格化好之后会通知一次，那时再换上真正该播的那一份
    final file = File(p.join(cacheDir.path, '$id.$extension'));
    return file.existsSync() && file.lengthSync() > 0 ? file.path : null;
  }

  PickedMediaStatus statusOf(int id) => _status[id] ?? PickedMediaStatus.absent;

  /// 下不下来的原因（可直接展示）；没失败时为 null
  String? failureOf(int id) => _failure[id];

  /// 已经固定住的那些
  Set<int> get pinned => Set.unmodifiable(_pinned);

  /// 还没就绪的固定素材。导出前要拿它拦一道——素材没齐就导，
  /// 导出来的片子里会缺画面
  List<int> get notReady => [
        for (final id in _pinned)
          if (_status[id] != PickedMediaStatus.ready) id,
      ];

  /// 固定住这条素材：排进下载队列。已经在下、已经就绪、或者**上次就存在本地**
  /// 的不重复排。
  ///
  /// 那个「本地已有」的判断不能少：状态是内存里的，app 一关就没了，
  /// 重开任务时一百多条全被当成没下过重排一遍队列——文件其实没重下
  /// （下载器会跳过已存在的），但底部横幅会闪出「正在把 91 条已选素材
  /// 存到本地」并慢慢往下掉，人看到的就是「怎么又下一遍」。
  void pin(int id) {
    _pinned.add(id);
    final status = _status[id];
    if (status == PickedMediaStatus.ready ||
        status == PickedMediaStatus.downloading) {
      return;
    }
    final local = localPathOf(id);
    if (local != null) {
      _paths[id] = local;
      _status[id] = PickedMediaStatus.ready;
      _queue.remove(id);
      return;
    }
    if (_queue.contains(id)) return;
    _queue.add(id);
    _pump();
  }

  /// 解除固定。**不删文件**——见类文档
  void unpin(int id) {
    if (!_pinned.remove(id)) return;
    _queue.remove(id);
    _notify();
  }

  /// 把固定集合整体对齐成 [ids]：多的解除、少的排队
  void pinAll(Set<int> ids) {
    for (final id in _pinned.toList()) {
      if (!ids.contains(id)) unpin(id);
    }
    for (final id in ids) {
      pin(id);
    }
    // 整批认领完通知一次。逐条通知的话，一百多条会把整个工作台重建一百多次
    _notify();
  }

  /// 重试一条下失败的
  void retry(int id) {
    _status.remove(id);
    _failure.remove(id);
    pin(id);
  }

  void _pump() {
    while (_running < concurrency && _queue.isNotEmpty) {
      final id = _queue.removeAt(0);
      _running++;
      _status[id] = PickedMediaStatus.downloading;
      _notify();
      unawaited(_download(id));
    }
  }

  Future<void> _download(int id) async {
    try {
      _paths[id] = await fetch(id);
      // 下载期间可能已经被取消勾选了，状态照记——文件确实在本地，
      // 下次再勾上就是秒好
      _status[id] = PickedMediaStatus.ready;
      _failure.remove(id);
    } catch (e) {
      _status[id] = PickedMediaStatus.failed;
      _failure[id] = _describe(e);
      AppLog.warn('已选素材 $id 落地失败：$e');
    } finally {
      _running--;
      _notify();
      if (!_disposed) _pump();
    }
  }

  /// 把异常翻成用户能照做的一句话
  static String _describe(Object e) {
    final text = '$e';
    if (text.contains('没有可用的下载地址') || text.contains('已被删除')) {
      return '素材库里已经找不到这条素材了，请换一条';
    }
    if (text.contains('SocketException') || text.contains('HandshakeException')) {
      return '网络不通，稍后重试';
    }
    if (text.contains('HTTP 401') || text.contains('登录')) {
      return '妙啊登录已过期，请重新登录后重试';
    }
    return '下载失败：$text';
  }

  /// 配额回收：总量超过 [quotaBytes] 时，按最久没被访问过的顺序删掉
  /// **未固定**的文件。固定住的一律不动——那是用户方案里正在用的素材。
  ///
  /// 返回删掉了多少字节。放在后台跑，删不掉的跳过就是了。
  int sweep() {
    if (!cacheDir.existsSync()) return 0;
    final files = <({File file, int id, int size, DateTime at})>[];
    var total = 0;
    for (final entity in cacheDir.listSync()) {
      if (entity is! File) continue;
      final id = int.tryParse(p.basenameWithoutExtension(entity.path));
      if (id == null) continue;
      final stat = entity.statSync();
      total += stat.size;
      if (_pinned.contains(id)) continue;
      files.add((file: entity, id: id, size: stat.size, at: stat.accessed));
    }
    if (total <= quotaBytes) return 0;

    files.sort((a, b) => a.at.compareTo(b.at));
    var freed = 0;
    for (final entry in files) {
      if (total - freed <= quotaBytes) break;
      try {
        entry.file.deleteSync();
        freed += entry.size;
        _status.remove(entry.id);
      } catch (e) {
        AppLog.warn('清理素材缓存失败（${entry.file.path}）：$e');
      }
    }
    if (freed > 0) _notify();
    return freed;
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _queue.clear();
    super.dispose();
  }
}
