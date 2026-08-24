import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../core/miaoa/candidate_probe.dart';
import '../../core/miaoa/miaoa_content_service.dart';
import '../../core/miaoa/miaoa_exception.dart';
import '../../core/miaoa/miaoa_failure.dart';
import 'picking_messages.dart';

/// 候选怎么看：台词列表 / 画面网格。
///
/// 整体替换换的是「一句台词对应的一段画面」，用户先要看的是这条素材原本在
/// 说什么；镜头替换挑的就是画面，摆台词列表反而绕远。
enum CandidateView { transcript, gallery }

/// 候选面板的装载状态
enum CandidateSearchStatus {
  /// 还没检索过（刚进页面 / 刚切到一个新作用域）
  idle,

  /// 检索中
  loading,

  /// 检索完成（**含 0 条**——0 条不是失败，引导语由页面按检索方式给）
  ready,

  /// 检索失败，[CandidateSearchController.failureMessage] 是可直接展示的中文
  failed,
}

/// 一条候选素材在候选面板上的展示状态：素材本体 + 规格探测进度。
///
/// [spec] 为 null 有两种含义，靠 [probing] 区分：探测中（显示「探测中」占位）
/// 与探测失败（**不显示**时长差徽标，而不是显示一个 0 冒充出来的假数据）。
@immutable
class CandidateEntry {
  final CandidateMaterial material;
  final CandidateSpec? spec;
  final bool probing;

  const CandidateEntry({
    required this.material,
    this.spec,
    required this.probing,
  });

  CandidateEntry settled(CandidateSpec? spec) =>
      CandidateEntry(material: material, spec: spec, probing: false);
}

/// 候选素材检索 + 规格探测的编排。
///
/// 两条性能约束（本项目踩过的坑）：
/// - 规格探测约 3 秒/条，二十条串行要一分钟。这里用工作池并发，且**边探边填**
///   （每完成一条就通知一次），让用户先看到卡片再看到时长；
/// - 一次性把二十条 ffprobe 全打出去会挤占网络与进程数，因此并发有上限。
///
/// 竞态：用户可以在结果回来之前切检索方式/切镜头，慢到的旧结果绝不能覆盖新的
/// （界面会「闪回」上一次的候选），因此每次检索领一个代次号，回写前先核对。
class CandidateSearchController extends ChangeNotifier {
  final MiaoaContentService service;
  final CandidateProbe probe;

  /// 同时在跑的 ffprobe 数上限
  final int probeConcurrency;

  CandidateSearchController({
    required this.service,
    required this.probe,
    this.probeConcurrency = 4,
    this.projectIds = const [],
    this.pageSize = 40,
  });

  /// 检索限定在哪些项目内；空表示不限项目（我的全部项目聚合）。
  /// 素材库里四万多条分镜横跨几十个项目，不限项目搜出来的大多用不上。
  List<int> projectIds;

  CandidateSearchStatus _status = CandidateSearchStatus.idle;
  String? _failureMessage;
  MiaoaFailureKind? _failureKind;
  List<CandidateEntry> _entries = const [];
  int _total = 0;
  int _skipped = 0;

  /// 检索代次：每发起一次检索自增，回写前核对，过期结果直接丢弃
  int _generation = 0;
  bool _disposed = false;

  CandidateSearchStatus get status => _status;

  /// 失败原因（已是可直接展示的中文；成功时为 null）
  String? get failureMessage => _failureMessage;

  /// 失败成因分类；UI 靠它决定动作按钮（登录失效给「重新登录」，其余给「重试」）
  MiaoaFailureKind? get failureKind => _failureKind;

  List<CandidateEntry> get entries => _entries;

  /// 命中总数（不只是当前这一页）
  int get total => _total;

  /// 因返回内容畸形而被跳过的条数（如实带出，不静默丢弃）
  int get skipped => _skipped;

  /// 当前页码（从 1 开始）
  int get page => _page;
  int _page = 1;

  /// 每页条数
  final int pageSize;

  /// 总页数（至少 1 页，免得界面显示「第 1/0 页」）
  int get pageCount =>
      _total <= 0 ? 1 : ((_total + pageSize - 1) ~/ pageSize);

  bool get hasPrevPage => _page > 1;
  bool get hasNextPage => _page < pageCount;

  /// 上一次检索是什么——翻页要拿它换一页重跑。null 表示还没检索过。
  Future<CandidatePage> Function(int page)? _lastQuery;

  Future<void> searchByTags({
    required List<int> tagIds,
    String mode = 'or',
  }) =>
      _start((page) => service.searchByTags(
            tagIds: tagIds,
            mode: mode,
            projectIds: projectIds,
            page: page,
            pageSize: pageSize,
          ));

  Future<void> searchByDescription(String keyword,
          {List<int> tagIds = const []}) =>
      _start((page) => service.searchByDescription(
            keyword: keyword,
            tagIds: tagIds,
            projectIds: projectIds,
            page: page,
            pageSize: pageSize,
          ));

  /// 按文件名搜（兜底：标签和描述都筛不到时，直接按名字捞）
  Future<void> searchByName(String keyword,
          {List<int> tagIds = const []}) =>
      _start((page) => service.searchByName(
            keyword: keyword,
            tagIds: tagIds,
            projectIds: projectIds,
            page: page,
            pageSize: pageSize,
          ));

  /// 按台词语义搜（参考片这一句在说什么，就找说同类话的分镜）
  Future<void> searchByVoiceover(String keyword,
          {List<int> tagIds = const []}) =>
      _start((page) => service.searchByVoiceover(
            keyword: keyword,
            tagIds: tagIds,
            projectIds: projectIds,
            page: page,
            pageSize: pageSize,
          ));

  Future<void> searchByImage(String fileKey,
          {List<int> tagIds = const []}) =>
      _start((page) => service.searchByImage(
            fileKey: fileKey,
            tagIds: tagIds,
            projectIds: projectIds,
            page: page,
            pageSize: pageSize,
          ));

  /// 翻到某一页。越界直接忽略——把「第 0 页」发给服务端只会拿回一个错误。
  Future<void> goToPage(int page) async {
    final query = _lastQuery;
    if (query == null || page < 1 || page > pageCount || page == _page) return;
    _page = page;
    await _run(() => query(page));
  }

  Future<void> nextPage() => goToPage(_page + 1);
  Future<void> prevPage() => goToPage(_page - 1);

  /// 失败后原样重发上一次检索（重新登录回来、网络恢复后走这里）。
  /// 没有可重发的检索时静默返回——按钮本就不该在那种状态下出现
  Future<void> retry() async {
    final query = _lastQuery;
    if (query == null) return;
    await _run(() => query(_page));
  }

  /// 新的检索：一律从第 1 页开始。换了检索键还停在第 7 页，
  /// 用户看到的会是一片空白（新结果没那么多页）。
  Future<void> _start(Future<CandidatePage> Function(int page) query) {
    _lastQuery = query;
    _page = 1;
    return _run(() => query(1));
  }

  /// 清空候选（切到没有可检索键的作用域时用），回到 idle
  void clear() {
    _generation++;
    _lastQuery = null;
    _page = 1;
    _entries = const [];
    _total = 0;
    _skipped = 0;
    _failureMessage = null;
    _failureKind = null;
    _status = CandidateSearchStatus.idle;
    _notify();
  }

  Future<void> _run(Future<CandidatePage> Function() search) async {
    final generation = ++_generation;
    _status = CandidateSearchStatus.loading;
    _failureMessage = null;
    _failureKind = null;
    _entries = const [];
    _notify();

    final CandidatePage page;
    try {
      page = await search();
    } catch (e) {
      if (generation != _generation) return; // 过期的失败同样不该覆盖新结果
      _status = CandidateSearchStatus.failed;
      // 网关已经把 401/403/未安装/超时翻译成可照做的中文，原样透出
      _failureMessage = describeSearchFailure(e);
      _failureKind = e is MiaoaException ? e.kind : null;
      _entries = const [];
      _notify();
      return;
    }
    if (generation != _generation) return;

    _status = CandidateSearchStatus.ready;
    _total = page.total;
    _skipped = page.skipped;
    // 先把卡片铺出来（规格标为探测中），不等 ffprobe——等的话用户要盯一分钟空白。
    // **按素材库给的顺序原样展示**，不做客户端重排。
    //
    // 曾经按标签重合度重排过，实测无效且误导：S1 的六个标签「满足其一」
    // 搜出 5437 条，而其中 5437 条全部来自「实拍」这一个标签——它在这个
    // 项目里几乎等于「所有素材」。第一页 20 条重合度全是 1，排了跟没排
    // 一样；真正 2/6 的素材在第 50 页开外，而我们只拿到第一页。
    // 排一页 20 条制造出「已经排过序」的错觉，比不排更糟。
    _entries = [
      for (final m in page.items) CandidateEntry(material: m, probing: true),
    ];
    _notify();

    await _probeAll(generation);
  }

  /// 工作池并发探测：结果按素材 id 回填，每填一条通知一次（渐进填充）
  Future<void> _probeAll(int generation) async {
    final materials = _entries.map((e) => e.material).toList(growable: false);
    var next = 0;

    Future<void> worker() async {
      while (true) {
        if (generation != _generation) return;
        final i = next++;
        if (i >= materials.length) return;
        final material = materials[i];
        final spec = await probe.probe(
          materialId: material.id,
          previewUrl: material.previewUrl,
        );
        if (generation != _generation) return;
        _settle(material.id, spec);
      }
    }

    await Future.wait(List.generate(
        math.min(probeConcurrency, materials.length), (_) => worker()));
  }

  /// 按素材 id 回填（不按下标）：翻页/重排之后下标会错位，id 不会
  void _settle(int materialId, CandidateSpec? spec) {
    _entries = List.unmodifiable([
      for (final e in _entries)
        e.material.id == materialId ? e.settled(spec) : e,
    ]);
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    // 代次自增让在飞的检索/探测在回写前就退出，不再触碰已销毁的对象
    _generation++;
    super.dispose();
  }
}
