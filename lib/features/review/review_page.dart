import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:flutter/material.dart';

import '../shared/thumb_image.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/export/speed_fit.dart';
import '../../core/ffmpeg/process_runner.dart';
import '../../core/ffmpeg/thumbnail_service.dart';
import '../../core/models/renew_task.dart';
import '../../core/models/semantic_unit.dart';
import '../../core/models/unit_uid.dart';
import '../../core/replacement/picked_material.dart';
import '../../core/review/review_receipt.dart';
import '../../core/storage/agent_presence.dart';
import '../../core/storage/agent_request.dart';
import '../../core/replacement/unit_base.dart';
import '../../core/log/app_log.dart';
import '../../core/storage/doc_watch.dart';
import '../../core/storage/edit_stamp.dart';
import '../../core/storage/task_media.dart';
import '../../core/storage/task_mutation.dart';
import '../director/tag_picker.dart';
import '../picking/picking_providers.dart';
import '../settings/settings_providers.dart';
import '../tasks/new_task_wizard/wizard_providers.dart';
import '../tasks/task_id_badge.dart';
import '../tasks/gui_task_mutation.dart';
import '../tasks/task_list_controller.dart';
import 'review_hover_player.dart';

/// 审核页：人过一遍 Agent 挑的候选，点掉不要的，一次确认。
///
/// 「Agent 干活 → 人把关 → 导出」闭环里人把关那一环。交互按「快速扫片」
/// 设计：**悬停即播**（有声、循环）、**点卡片即剔除/恢复**——审核是把
/// 不要的挑出来，不是重新挑一遍，所以不摆一排勾选框。
///
/// 版式：左侧位置栏（结构 + 进度，点击跳到对应段），右侧按位置分组的卡片
/// 网格。确认那一刻剔除落进任务、写回执（见 [ReviewReceipt]），Agent 用
/// `review-result` 取结果。
class ReviewPage extends ConsumerStatefulWidget {
  final RenewTask task;

  /// 工作台内嵌模式：确认时把决定交回工作台，由它在自己的会话里应用
  /// ——同一个人的同一次编辑会话，不该有第二条落盘路径。为 null 时是
  /// **独立模式**（CLI 唤醒 / 任务列表进入）：确认时自己写盘
  final void Function(List<ReviewDecision> decisions)? onApply;

  /// 标签在这一页被改过时回调（**内嵌模式必须接**）。
  ///
  /// 为什么不让审核页自己写盘：内嵌时工作台开着同一条任务，两边都是整份
  /// 任务对象落库，谁后写谁赢——不交回去的话，人在这里改的标签会被工作台
  /// 的下一次保存抹掉。为 null 时是独立模式，自己写。
  final void Function(List<SemanticUnit> units)? onTagsChanged;

  /// 测试注入：假播放器（真实现碰 libmpv）、假素材解析、假抽帧
  final ReviewHoverPlayer? hoverPlayer;
  final Future<String> Function(int materialId)? resolveMedia;
  /// 抽「本来的样子」那一张。第三个参数是**取自哪条素材**（底片固定过的
  /// 单元），null 表示取自任务原片——签名里带着它，是因为 `??` 两边类型
  /// 对不上时 Dart 会推断成裸 `Function`，参数个数错要到运行时才炸
  final Future<String?> Function(int startMs, int endMs, int? candidateId)?
      extractOriginalThumb;

  const ReviewPage({
    super.key,
    required this.task,
    this.onApply,
    this.onTagsChanged,
    this.hoverPlayer,
    this.resolveMedia,
    this.extractOriginalThumb,
  });

  @override
  ConsumerState<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends ConsumerState<ReviewPage> {
  /// 这一页手上的那份任务。**不是 `widget.task`**——进门那一刻的快照
  /// 过一会儿就旧了：人开着这一页的时候 CLI 照样在写盘（`apply plans`
  /// 被这一页回了 `unsupported` 之后，它就是自己写的），新候选落在盘上，
  /// 而这一页还按老样子判「这一页上没有这些候选」。见 [_reloadIfStale]
  late RenewTask _task = widget.task;

  /// 上一次读到这份数据时盘上的指纹。对不上 = 这期间有人写过
  String? _taskPrint;

  /// 单元列表的**可变副本**：审核页能就地改标签，改完这里先变，
  /// 再按模式落库（内嵌模式交回工作台，独立模式自己写盘）
  late List<SemanticUnit> _units = [...(widget.task.units ?? const [])];

  late List<ReviewItem> _items =
      collectReviewItems(widget.task.replacementsFor(_units));

  /// 被剔除的候选。默认空 = 全保留：审核是把不要的挑出来
  final Set<String> _dropped = {};

  late final ReviewHoverPlayer _hover =
      widget.hoverPlayer ?? MediaKitHoverPlayer();

  /// 当前悬停在哪张卡上（null = 没有）。整页共用一个播放器，
  /// 只有这张卡把缩略图换成视频
  String? _hoveringKey;
  Timer? _hoverDebounce;

  final ScrollController _scroll = ScrollController();
  final Map<String, GlobalKey> _sectionKeys = {};

  String? _error;

  /// 原片段落的首帧图（分组 id → 本地 jpg）。抽出来一张补一张
  final Map<String, String> _originThumbs = {};

  /// Agent 此刻在这个任务上做什么。非 null = 它在干活：页面**跟着它走**
  /// （滚到它动的那张卡），但人照样能自己上手——打开这一页从来不需要
  /// 先「取得」什么，它就是打开
  AgentPresence? _agent;
  Timer? _agentPoll;

  /// 每张卡的位置锚点，用来把 Agent 动到的那张滚进视野
  final Map<String, GlobalKey> _cardKeys = {};

  /// Agent 刚代办完什么（顶部轻提示）。人正开着这一页指挥它时走这条路
  String? _delegateNote;

  static String keyOf(ReviewItem item) =>
      '${item.unit}/${item.shot}/${item.material}';

  @override
  void initState() {
    super.initState();
    final dataDir = ref.read(dataDirProvider);
    if (dataDir != null) {
      _taskPrint = taskFingerprint(dataDir, widget.task.id);
    }
    _loadOriginThumbs();
    _watchAgent();
  }

  /// 盯着 Agent：**两个方向都要接**。
  ///
  /// - 它在干活（在场状态）→ 页面转只读，把它动的那张卡滚到眼前，展示完回执
  /// - 它请我代办（代办请求）→ 我来点这几张卡。剔除是界面里的临时状态，
  ///   人按「确认」才落盘，所以只能由这一页执行，不能让它绕过去写盘
  void _watchAgent() {
    _agentPoll?.cancel();
    _agentPoll = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      final dataDir = ref.read(dataDirProvider);
      if (dataDir == null) return;
      unawaited(_handleDelegated(dataDir));
      _followAgent(dataDir);
    });
  }

  /// 正在服务一张代办单。**轮询是 500ms 一次、而服务这件事要等一次重读**
  /// ——不挡一下的话，下一轮会从同一个目录再取走一张单子并发地做
  bool _serving = false;

  Future<void> _handleDelegated(Directory dataDir) async {
    if (_serving) return;
    final request =
        consumeAgentRequest(dataDir: dataDir, taskId: widget.task.id);
    if (request == null) return;
    _serving = true;
    try {
      // **先对一眼盘**：单子上点的候选可能是这一页打开之后才落盘的
      await _reloadIfStale(dataDir);
      if (!mounted) return;
      _serveDelegated(dataDir, request);
    } finally {
      _serving = false;
    }
  }

  /// 盘上那份比手上这份新的话，重读一次并把派生视图全部重算。
  ///
  /// **按内容指纹判定，不看「Agent 在不在场」**：在场是 500ms 轮询出来的，
  /// 窗口里照样对不上（`doc_watch.dart` 里那两条真机教训同源）。
  ///
  /// **只在独立模式做。** 内嵌模式下工作台才是这条任务的写入方，它手上
  /// 那份比盘上新（自动保存有 800ms 防抖），这时重读盘会把人刚拖的边界
  /// 挤掉——那是拿一个新问题换掉旧问题。
  Future<void> _reloadIfStale(Directory dataDir) async {
    if (widget.onApply != null) return;
    final now = taskFingerprint(dataDir, widget.task.id);
    if (now == _taskPrint) return;
    final fresh =
        await ref.read(taskRepositoryProvider).findById(widget.task.id);
    if (!mounted) return;
    // 读不到（在这期间被删了）就保持原样：不拿旧的冒充新的，也不在这里
    // 报错——「任务不见了」这一页有自己的出口（落库时 saved == null）
    if (fresh == null) return;
    setState(() {
      _taskPrint = now;
      _adoptTask(fresh);
    });
    unawaited(_loadOriginThumbs());
  }

  /// 换上新读到的那份，派生视图**全部重算**——漏掉一个就会出现
  /// 「卡片是新的、分组还是旧的」这种更难查的错位
  void _adoptTask(RenewTask fresh) {
    _task = fresh;
    _units = [...(fresh.units ?? const [])];
    _items = collectReviewItems(fresh.replacementsFor(_units));
    _previewKeys = _buildPreviewKeys();
    _sections = _buildSections();
    // 剔除是这一页的临时状态。盘上已经没有的那几张卡，标记跟着作废——
    // 留着的话它会在下一次「确认」时对着一个不存在的位置生效
    _dropped.removeWhere((k) => !_items.any((i) => keyOf(i) == k));
  }

  void _serveDelegated(Directory dataDir, AgentRequest request) {
    final keep = request.kind == 'review.keep';
    if (request.kind != 'review.drop' && !keep) {
      // **带上 unsupported**：这句话说的是「人恰好开着审片台」，
      // 不是「这件事做不成」。不带的话，`ishkafel export` 会因为
      // 「人在审片台上看这条任务」而失败——那正是这一批要杀的那句
      // 「我做不了，因为软件那边不让」（见 [AgentRequestResult.unsupported]）
      writeAgentRequestResult(
          dataDir: dataDir,
          taskId: widget.task.id,
          id: request.id,
          ok: false,
          unsupported: true,
          message: '审片台接不了「${request.kind}」这件事——你自己做就行');
      return;
    }
    final decisions = [
      for (final raw in (request.payload['decisions'] as List? ?? const []))
        ?ReviewDecision.tryFromJson(raw),
    ];
    // 整批拒绝：一条编号对不上就全不做。不然人以为剔了两条、实际剔了一条
    final missing = [
      for (final d in decisions)
        if (!_items.any((i) =>
            i.unit == d.unit && i.shot == d.shot && i.material == d.material))
          '第 ${d.unit + 1} 段'
              '${d.shot == null ? '' : '第 ${d.shot! + 1} 镜'}的素材 ${d.material}',
    ];
    if (decisions.isEmpty || missing.isNotEmpty) {
      writeAgentRequestResult(
        dataDir: dataDir,
        taskId: widget.task.id,
        id: request.id,
        ok: false,
        message: decisions.isEmpty
            ? '一条决定都没有'
            : '这一页上没有这些候选：${missing.join('、')}',
      );
      return;
    }
    setState(() {
      for (final d in decisions) {
        final key = '${d.unit}/${d.shot}/${d.material}';
        d.keep ? _dropped.remove(key) : _dropped.add(key);
      }
      final what = keep ? '恢复' : '剔除';
      _delegateNote = 'Agent $what了 ${decisions.length} 条，'
          '按下面的「确认」才会落进方案';
    });
    // 滚到它动的最后一张，人的视线跟着走
    final last = decisions.last;
    _scrollToCard('${last.unit}/${last.shot}/${last.material}');
    writeAgentRequestResult(
      dataDir: dataDir,
      taskId: widget.task.id,
      id: request.id,
      ok: true,
      message: '已在界面上标记 ${decisions.length} 条，等人按确认',
    );
  }

  void _followAgent(Directory dataDir) {
    final now = readAgentPresence(dataDir: dataDir, taskId: widget.task.id);
    final was = _agent;
    final changed = (was == null) != (now == null) ||
        was?.action != now?.action ||
        was?.focus?.materialId != now?.focus?.materialId;
    if (!changed) return;
    setState(() => _agent = now);
    final focus = now?.focus;
    if (focus?.materialId != null) {
      _scrollToCard(
          '${focus!.unitIndex ?? focus.lineIndex}/${focus.shotIndex}/'
          '${focus.materialId}');
    }
    if (now != null && now.step > 0) {
      // 真的展示完（滚动落定）才回执——Agent 靠它决定什么时候走下一步
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future<void>.delayed(const Duration(milliseconds: 320), () {
          if (!mounted) return;
          writeAgentAck(
              dataDir: dataDir, taskId: widget.task.id, step: now.step);
        });
      });
    }
  }

  void _scrollToCard(String key) {
    final ctx = _cardKeys[key]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(ctx,
        duration: const Duration(milliseconds: 250),
        alignment: 0.4,
        curve: Curves.easeOut);
  }

  /// 给每个位置组的原片段落抽一张首帧图（取中点：两端常踩在转场上，
  /// 抽出来是糊的）。按任务缓存，抽过的直接用
  Future<void> _loadOriginThumbs() async {
    for (final section in _sections) {
      final start = section.originStartMs;
      final end = section.originEndMs;
      if (start == null || end == null) continue;
      // 取自原片的那些要有原片；取自素材的（底片固定过）不需要
      if (section.originCandidateId == null &&
          _task.sourcePath == null) {
        continue;
      }
      try {
        final path = await (widget.extractOriginalThumb ?? _extractThumb)(
            start, end, section.originCandidateId);
        if (!mounted) return;
        if (path != null && File(path).existsSync()) {
          setState(() => _originThumbs[section.id] = path);
        }
      } catch (_) {
        // 抽不出来就保持占位图，悬停仍能播真画面——不值得为一张缩略图报错
      }
    }
  }

  Future<String?> _extractThumb(
      int startMs, int endMs, int? candidateId) async {
    final dataDir = ref.read(dataDirProvider);
    final source = _originPathOf(candidateId);
    if (dataDir == null || source == null) return null;
    final dir = Directory(
        p.join(dataDir.path, 'review_thumbs', widget.task.id))
      ..createSync(recursive: true);
    // 素材那张要单独存：不带 id 的话，原片同一个时间点的缓存会被当成
    // 它的，抽出来是别的画面
    final tag = candidateId == null ? 'orig' : 'base$candidateId';
    final out = p.join(dir.path, '${tag}_${startMs}_$endMs.jpg');
    if (File(out).existsSync()) return out;
    await ThumbnailService(run: const ResolvingProcessRunner().call)
        .extractCover(
      videoPath: source,
      outPath: out,
      atSeconds: ((startMs + endMs) / 2) / 1000.0,
      height: 480,
    );
    return out;
  }

  @override
  void dispose() {
    _agentPoll?.cancel();
    _hoverDebounce?.cancel();
    _hover.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ---- 数据视图 ----

  PickedMaterial? _materialOf(int id) {
    for (final m in _task.pickedMaterials) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// 标了 ★ 的那些（预览版）：审核的人该知道哪条是 Agent 的首选
  late Set<String> _previewKeys = _buildPreviewKeys();

  Set<String> _buildPreviewKeys() {
    final keys = <String>{};
    final replacements = _task.replacementsFor(_units);
    for (var u = 0; u < replacements.length; u++) {
      final r = replacements[u];
      if (r.wholeCandidateIds.isNotEmpty) {
        keys.add('$u/null/${r.wholePreviewId ?? r.wholeCandidateIds.first}');
      }
      for (final e in r.shotCandidateIds.entries) {
        if (e.value.isEmpty) continue;
        keys.add('$u/${e.key}/${r.shotPreviewIds[e.key] ?? e.value.first}');
      }
    }
    return keys;
  }

  /// 「本来的样子」该读哪个文件：底片固定过的单元读那条素材，其余读原片
  String? _originPathOf(int? candidateId) {
    if (candidateId == null) return _task.sourcePath;
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) return null;
    return TaskMedia(dataDir: dataDir, taskId: widget.task.id)
        .localMaterial(candidateId);
  }

  /// 位置分组（保持出现顺序）
  late List<_Section> _sections = _buildSections();

  List<_Section> _buildSections() {
    final map = <String, _Section>{};
    final units = _task.units ?? const [];
    for (final item in _items) {
      final id = '${item.unit}/${item.shot}';
      map.putIfAbsent(id, () {
        final unit = item.unit < units.length ? units[item.unit] : null;
        final shot = unit != null &&
                item.shot != null &&
                item.shot! < unit.shots.length
            ? unit.shots[item.shot!]
            : null;
        // 「这一段本来的样子」取自哪个文件的哪一段：整段替换是整个单元，
        // 镜头替换是那个镜头。
        //
        // **底片固定过的单元取的是那条素材**，不是原片——它的镜头坐标是
        // 「单元起点 + 素材内偏移」，照原片那个时间点抽出来的是一段毫不
        // 相干的画面，而这张卡的用处正是「拿它当参照物比对候选」
        final onBase = unit != null && hasOwnBaseShots(unit);
        final shift = onBase ? -unit.startMs : 0;
        final originStart =
            (item.shot == null ? unit?.startMs : shot?.startMs).plusOrNull(shift);
        final originEnd =
            (item.shot == null ? unit?.endMs : shot?.endMs).plusOrNull(shift);
        return _Section(
          id: id,
          unitIndex: item.unit,
          shotIndex: item.shot,
          title: item.shot == null
              ? 'U${item.unit + 1} · 整段替换'
              : 'U${item.unit + 1} · S${item.shot! + 1}',
          transcript: unit?.transcript ?? '',
          slotMs: item.shot == null ? null : shot?.durationMs,
          originStartMs: originStart,
          originEndMs: originEnd,
          originCandidateId: onBase ? unit.baseCandidateId : null,
          items: [],
        );
      });
      map[id]!.items.add(item);
    }
    return map.values.toList();
  }

  int get _droppedCount => _dropped.length;

  // ---- 交互 ----

  void _toggle(ReviewItem item) {
    // Agent 正在动它——这时人点一下，两边会打架，而且它下一步就把界面
    // 覆盖回去了。想插手就等它收工（或在 Agent 那头喊停）
    if (_agent != null) return;
    final key = keyOf(item);
    setState(() {
      _dropped.contains(key) ? _dropped.remove(key) : _dropped.add(key);
    });
  }

  void _onHover(
    String key,
    bool entered, {
    required Future<String> Function() resolve,
    int? startMs,
    int? endMs,
  }) {
    _hoverDebounce?.cancel();
    if (!entered) {
      if (_hoveringKey == key) {
        setState(() => _hoveringKey = null);
        _hover.stop();
      }
      return;
    }
    // 250ms 防抖：鼠标扫过一排卡时别把每张都拉起来播一下
    _hoverDebounce = Timer(const Duration(milliseconds: 250), () async {
      if (!mounted) return;
      setState(() => _hoveringKey = key);
      try {
        final path = await resolve();
        if (!mounted || _hoveringKey != key) return;
        await _hover.play(path, startMs: startMs, endMs: endMs);
      } catch (_) {
        if (mounted && _hoveringKey == key) {
          setState(() => _hoveringKey = null);
        }
      }
    });
  }

  Future<String> _resolveMaterial(int id) {
    final resolve = widget.resolveMedia ??
        (int id) async {
          final fetch = ref.read(materialFetcherProvider);
          if (fetch == null) throw StateError('素材下载器未就绪');
          return fetch(widget.task.id, id);
        };
    return resolve(id);
  }

  void _jumpTo(String sectionId) {
    final key = _sectionKeys[sectionId];
    final ctx = key?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 250),
          alignment: 0,
          curve: Curves.easeOut);
    }
  }

  Future<void> _confirm() async {
    final decisions = [
      for (final item in _items)
        ReviewDecision(
          unit: item.unit,
          shot: item.shot,
          material: item.material,
          keep: !_dropped.contains(keyOf(item)),
        ),
    ];

    // 工作台内嵌：决定交回工作台，它在自己的会话里应用并走既有的自动保存
    if (widget.onApply case final apply?) {
      apply(decisions);
      if (mounted) Navigator.of(context).pop(_outcome());
      return;
    }

    // 独立模式：这一页自己写盘。**剔除算在 fresh 的方案上**——审的这几分钟
    // 里 Agent 可能又往里加了候选，拿进门那一刻的快照算完整份写回去，
    // 新加的会连同被剔的一起消失
    try {
      final updated = await humanMutation(
        repo: ref.read(taskRepositoryProvider),
        dataDir: ref.read(dataDirProvider),
        actor: actorReview,
      ).apply(
        taskId: widget.task.id,
        op: 'review.prune',
        note: '人在审片台确认了这一轮候选的去留',
        edit: (fresh) {
          final units = fresh.units ?? const <SemanticUnit>[];
          final before = fresh.replacementsFor(units);
          final pruned = applyReviewDecisions(before, decisions);
          final materials = {for (final m in fresh.pickedMaterials) m.id: m};
          return TaskEdit(
            task: fresh.copyWith(
                replacementsByUid: RenewTask.byUid(units, pruned)),
            // 每条决定都带上素材本身的样子：只记 id 的话，Agent 看不出
            // 人不要的是哪一类（见 [reviewDecisionFacts]）
            before: {
              'candidates': collectReviewItems(before).length,
              'decisions': [
                for (final d in decisions) reviewDecisionFacts(d, materials),
              ],
            },
            after: {'candidates': collectReviewItems(pruned).length},
          );
        },
      );
      if (updated == null) {
        if (mounted) setState(() => _error = taskMissingMessage);
        return;
      }
      // **先看在不在，再碰 ref**：上面 await 了一次写盘，这期间页面可能
      // 已经销毁，那时 `ref.read` 会抛 StateError
      if (!mounted) return;
      await ref.read(taskListProvider.notifier).reload();
      if (!mounted) return;
      // 审核完回到来处——它不是终点站，主流程才是
      Navigator.of(context).pop(_outcome());
    } catch (e) {
      if (mounted) setState(() => _error = '确认失败：$e');
    }
  }

  ReviewOutcome _outcome() => ReviewOutcome(
      kept: _items.length - _droppedCount, dropped: _droppedCount);

  // ---- 视图 ----

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.surface,
          titleSpacing: 0,
          title: Row(children: [
            TaskIdBadge(task: _task),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: _titleText()),
          ]),
        ),
        body: _items.isEmpty
            ? const _EmptyState()
            : Column(children: [
                // Agent 在干活 / 刚替人干完活：两种都要在最显眼处说出来。
                // 界面不说话，人只会以为软件自己乱跳
                if (_agent != null) _agentBanner(_agent!),
                if (_agent == null && _delegateNote != null)
                  _delegateBanner(_delegateNote!),
                Expanded(child: _reviewBody()),
              ]),
        bottomNavigationBar: _items.isEmpty ? null : _confirmBar(),
      );

  Widget _titleText() => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('审核候选',
                  style: TextStyle(
                      fontSize: AppFontSize.emphasis,
                      fontWeight: FontWeight.w600)),
              Text(_task.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: AppFontSize.micro,
                      color: AppColors.textTertiary)),
            ],
          );

  Widget _reviewBody() => Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _railView(),
          const VerticalDivider(width: 1, color: AppColors.border),
          Expanded(child: _sectionsView()),
        ],
      );

  /// 左栏：位置导航 + 进度。审核是逐位置过一遍的活，要能看到全貌
  Widget _railView() => SizedBox(
        width: 220,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(
                  AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.xs),
              child: Text('位置',
                  style: TextStyle(
                      fontSize: AppFontSize.caption,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondary)),
            ),
            for (final section in _sections)
              _RailRow(
                title: section.title,
                kept: section.items
                    .where((i) => !_dropped.contains(keyOf(i)))
                    .length,
                total: section.items.length,
                onTap: () => _jumpTo(section.id),
              ),
          ],
        ),
      );

  Widget _sectionsView() => ListView(
        controller: _scroll,
        padding: const EdgeInsets.all(AppSpacing.xl),
        children: [
          const Text('悬停播放，点击剔除/恢复。确认后被剔除的从方案里拿掉，其余照旧。',
              style: TextStyle(
                  fontSize: AppFontSize.caption,
                  color: AppColors.textTertiary)),
          const SizedBox(height: AppSpacing.lg),
          for (final section in _sections) ...[
            KeyedSubtree(
              key: _sectionKeys.putIfAbsent(section.id, GlobalKey.new),
              child: _sectionHeader(section),
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.md,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // 原片这一段打头：审核就是「原来是什么 → 换成什么」的对比
                if (_task.sourcePath != null &&
                    section.originStartMs != null &&
                    section.originEndMs != null) ...[
                  _originalCard(section),
                  const Icon(Icons.arrow_forward,
                      size: 18, color: AppColors.textTertiary),
                ],
                for (final item in section.items)
                  _card(item, slotMs: section.slotMs),
              ],
            ),
            const SizedBox(height: AppSpacing.xl),
          ],
        ],
      );

  Widget _sectionHeader(_Section section) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Text(section.title,
                style: const TextStyle(
                    fontSize: AppFontSize.emphasis,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary)),
            if (section.slotMs case final ms?) ...[
              const SizedBox(width: AppSpacing.sm),
              Text('坑位 ${(ms / 1000).toStringAsFixed(1)}s',
                  style: const TextStyle(
                      fontSize: AppFontSize.caption,
                      color: AppColors.textTertiary)),
            ],
          ]),
          // 标签**独占一行、全部铺开**：挤在标题旁边的话，镜头层十来个标签
          // 会被压成很窄的一条。它们是这一段的检索键，看的就是「全都有哪些」
          _tagRow(section),
          if (section.transcript.isNotEmpty)
            Container(
              // 一行别超过这个宽度。**不是为了留白，是为了读得动**：
              // 1100px 一行是 100 多个汉字，眼睛扫到行尾再回到下一行行首
              // 很容易串行——而这段话正是人判断候选贴不贴题的依据
              // （2026-09-09 设计走查）
              constraints: const BoxConstraints(maxWidth: _transcriptMaxWidth),
              padding: const EdgeInsets.only(top: 2),
              // **台词不截断**：截成两行加省略号，等于把人要判断的东西藏起来
              // ——他正是靠这段话决定候选贴不贴题的
              child: Text(section.transcript,
                  style: const TextStyle(
                      fontSize: AppFontSize.caption,
                      height: 1.5,
                      color: AppColors.textSecondary)),
            ),
        ],
      );

  /// 台词一行最宽多少。约 45 个汉字——排版上舒服的行长是 45~75 个字符，
  /// 中文取下限那一档
  static const double _transcriptMaxWidth = 720;

  /// 这一段的标签。**摆出来，而且能就地改。**
  ///
  /// 为什么要摆在这里：标签就是这一段候选的检索键。人在这一屏判断候选
  /// 「像不像」的时候，得能看见它当初是按什么搜出来的——看不见就只能猜，
  /// 猜错了也只会反复剔除，问题根子（标签打偏了）一直没人动。
  ///
  /// 取哪一层跟着替换粒度走：整段替换检索用的是单元标签，逐镜头替换用的是
  /// 那个镜头的标签——摆另一层等于给人看一份跟这次检索无关的东西。
  Widget _tagRow(_Section section) {
    final tags = _tagsOf(section);
    // Agent 正在动这一页时不让人同时改同一处：不是「没有权限」，
    // 是两只手在同一个格子上互相抢——人改的会被下一次刷新盖掉，而他
    // 看不见。**横幅上把这件事说出来**（见 [_agentBanner]），不能只是
    // 把按钮藏起来。它一收工立刻恢复。
    //
    // 根因是这两个工作页整份落盘；改成按字段合并之后这道闸就不必存在了
    final editable = _agent == null;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: Wrap(
        spacing: AppSpacing.xs,
        runSpacing: AppSpacing.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (tags.isEmpty)
            const Text('未打标',
                style: TextStyle(
                    fontSize: AppFontSize.caption,
                    color: AppColors.textTertiary))
          else
            for (final tag in tags) _chip(tag),
          if (editable)
            TextButton(
              key: ValueKey('review-edit-tags-${section.id}'),
              onPressed: () => unawaited(_editTags(section)),
              style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm, vertical: 0),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              child: const Text('改标签',
                  style: TextStyle(fontSize: AppFontSize.caption)),
            ),
        ],
      ),
    );
  }

  /// 改这一段的标签：打开选择器（当前的预先带勾），勾选/取消都在里面完成
  /// ——删一个和加一个是同一个动作，跟编导台那边一致。
  ///
  /// **只给这条任务自己的标签组**（onlyPreferred）：标签是下一步的检索键，
  /// 给出任务标签组以外的词等于让人挑一个这个项目根本没素材的标签，
  /// 搜完才发现是空的，那时也不知道是标签选错了。
  Future<void> _editTags(_Section section) async {
    final groups = section.shotIndex == null
        ? _task.unitTagGroups
        : _task.shotTagGroups;
    final picked = await showTagPicker(
      context,
      tags: ref.read(miaoaTagServiceProvider),
      selected: _tagsOf(section),
      preferredGroupIds: {for (final g in groups) g.id},
      onlyPreferred: true,
    );
    if (picked == null || !mounted) return;
    _applyTags(section, [for (final t in picked) t.name]);
  }

  /// 标签改动落地。
  ///
  /// **内嵌模式不自己写盘**：那时工作台开着同一条任务，它保存的是整份任务
  /// 对象，这边再写一次，谁后写谁赢——人在审核页改的标签会被工作台的下一次
  /// 保存抹掉。所以交回它，由它跟切分改动走同一条保存通路。
  void _applyTags(_Section section, List<String> tags) {
    setState(() => _units = _withTags(_units, section, tags));
    final onTagsChanged = widget.onTagsChanged;
    if (onTagsChanged != null) {
      onTagsChanged(_units);
      return;
    }
    // 独立模式：这份任务此刻归自己写
    if (section.unitIndex >= _units.length) return;
    unawaited(_saveTags(_units[section.unitIndex].uid, section.unitIndex,
        section.shotIndex, tags));
  }

  /// 把改好的标签落盘。**只动点名的那一个位置**——这一页手上的 `_units` 是
  /// 进门那一刻的整份，整份写回去会把 Agent 这期间改的切分抹掉。
  Future<void> _saveTags(String unitUid, int unitIndex, int? shotIndex,
      List<String> tags) async {
    try {
      final saved = await humanMutation(
        repo: ref.read(taskRepositoryProvider),
        dataDir: ref.read(dataDirProvider),
        actor: actorReview,
      ).apply(
        taskId: widget.task.id,
        op: 'unit.tags',
        where: {
          'unitUid': unitUid,
          'shotIndex': ?shotIndex,
        },
        note: shotIndex == null
            ? '人在审片台改了这一段的检索标签'
            : '人在审片台改了这一镜的检索标签',
        edit: (fresh) {
          final units = fresh.units ?? const <SemanticUnit>[];
          // **按身份重新定位**，不能拿进门那一刻的下标当 fresh 的下标用。
          // 还没发身份的单元（uid 是空串，老存档才有）没法按身份认领——
          // 拿空串去找会命中「第一个也没有 uid 的」，那是别人家的标签。
          // 这种只能退回按位置，而且不盖戳（戳认的就是身份）
          final i = isUnitUid(unitUid)
              ? units.indexWhere((u) => u.uid == unitUid)
              : (unitIndex < units.length && !isUnitUid(units[unitIndex].uid)
                  ? unitIndex
                  : -1);
          if (i < 0) {
            return TaskEdit(
              task: fresh,
              before: {'present': false},
              after: {'present': false, 'note': '这个单元在窗口内被删掉了'},
            );
          }
          final unit = units[i];
          if (shotIndex != null &&
              (shotIndex < 0 || shotIndex >= unit.shots.length)) {
            return TaskEdit(
              task: fresh,
              before: {'present': false},
              after: {'present': false, 'note': '这一镜在窗口内没了（切分变过）'},
            );
          }
          final before =
              shotIndex == null ? unit.tags : unit.shots[shotIndex].tags;
          return TaskEdit(
            task: fresh.copyWith(units: [
              for (var j = 0; j < units.length; j++)
                if (j != i)
                  units[j]
                else if (shotIndex == null)
                  unit.copyWith(tags: tags)
                else
                  unit.copyWith(shots: [
                    for (var s = 0; s < unit.shots.length; s++)
                      if (s == shotIndex)
                        unit.shots[s].copyWith(tags: tags)
                      else
                        unit.shots[s],
                  ]),
            ]),
            before: {'tags': before, 'transcript': unit.transcript},
            after: {'tags': tags},
            stampUnits:
                shotIndex == null && isUnitUid(unitUid) ? [unitUid] : const [],
            stampShots: shotIndex != null && isUnitUid(unitUid)
                ? [ShotRef(unitUid, shotIndex)]
                : const [],
          );
        },
      );
      if (saved == null && mounted) {
        setState(() => _error = taskMissingMessage);
      }
    } catch (e) {
      AppLog.warn('审片台改标签落库失败（taskId=${widget.task.id}）：$e');
      if (mounted) setState(() => _error = '标签没存上：$e');
    }
  }

  /// 这一段检索用的那一层标签
  List<String> _tagsOf(_Section section) {
    if (section.unitIndex >= _units.length) return const [];
    final unit = _units[section.unitIndex];
    final shotIndex = section.shotIndex;
    if (shotIndex == null) return unit.tags;
    return shotIndex < unit.shots.length ? unit.shots[shotIndex].tags : const [];
  }

  /// 原片卡：这一段本来的样子。不可剔除（它不是候选，是参照物），
  /// 悬停播的是原片的这个区间
  Widget _originalCard(_Section section) {
    final key = 'orig/${section.id}';
    final hovering = _hoveringKey == key;
    final source = _originPathOf(section.originCandidateId);
    if (source == null) return const SizedBox.shrink();
    final start = section.originStartMs!;
    final end = section.originEndMs!;
    return MouseRegion(
      onEnter: (_) => _onHover(key, true,
          resolve: () async => source, startMs: start, endMs: end),
      onExit: (_) => _onHover(key, false,
          resolve: () async => source, startMs: start, endMs: end),
      child: Container(
        key: Key('review-original-${section.id}'),
        width: 150,
        decoration: BoxDecoration(
          color: AppColors.surfaceCard,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: hovering ? AppColors.accentBlue : AppColors.accentBlueLight,
            width: hovering ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 9 / 16,
              child: ClipRRect(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(8)),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_originThumbs[section.id] case final thumb?)
                      ThumbImage(
                          key: Key('review-original-thumb-${section.id}'),
                          path: thumb)
                    else
                      Container(
                          color: AppColors.surfaceCard,
                          child: const Icon(Icons.theaters_outlined,
                              size: 32, color: AppColors.textTertiary)),
                    if (hovering) _hover.buildVideo(),
                    Positioned(
                      left: 6,
                      top: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.accentBlue,
                          borderRadius: BorderRadius.circular(AppRadius.xs),
                        ),
                        child: const Text('原片',
                            style: TextStyle(
                                fontSize: AppFontSize.micro,
                                color: Colors.white)),
                      ),
                    ),
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child:
                          _chip('${((end - start) / 1000).toStringAsFixed(1)}s'),
                    ),
                  ],
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.all(AppSpacing.xs),
              child: Text('这一段本来的样子',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: AppFontSize.micro,
                      color: AppColors.textTertiary)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card(ReviewItem item, {int? slotMs}) {
    final key = keyOf(item);
    final material = _materialOf(item.material);
    final dropped = _dropped.contains(key);
    final hovering = _hoveringKey == key;
    final thumb = material?.thumbPath;

    // 镜头替换要变速对齐坑位：倍率如实标出来，人看一眼就知道会不会像快进
    String? rate;
    if (slotMs != null && slotMs > 0 && material?.durationMs != null) {
      rate = SpeedFit.describe(
          SpeedFit.factorFor(candidateMs: material!.durationMs!, slotMs: slotMs));
    }

    return KeyedSubtree(
      // 位置锚点：Agent 动到哪张，就把哪张滚进视野
      key: _cardKeys.putIfAbsent(key, GlobalKey.new),
      child: MouseRegion(
      onEnter: (_) => _onHover(key, true,
          resolve: () => _resolveMaterial(item.material)),
      onExit: (_) => _onHover(key, false,
          resolve: () => _resolveMaterial(item.material)),
      child: GestureDetector(
        key: Key('review-card-$key'),
        onTap: () => _toggle(item),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 120),
          opacity: dropped ? 0.38 : 1,
          child: Container(
            width: 150,
            decoration: BoxDecoration(
              color: AppColors.surfaceRaised,
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(
                color: dropped
                    ? AppColors.red
                    : (hovering ? AppColors.accentBlue : AppColors.border),
                width: dropped || hovering ? 1.5 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AspectRatio(
                  aspectRatio: 9 / 16,
                  child: ClipRRect(
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(8)),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (thumb != null && File(thumb).existsSync())
                          ThumbImage(path: thumb)
                        else
                          // **说清为什么是空的**。只摆一个胶片图标的话，人
                          // 分不出「还没抽到帧」和「这条素材坏了」——而他
                          // 正要靠画面决定留不留（2026-09-09 设计走查：
                          // U1·S7 的预览版就是一块空灰底，什么都没说）
                          Container(
                            color: AppColors.surfaceCard,
                            padding: const EdgeInsets.all(AppSpacing.sm),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.movie_outlined,
                                    color: AppColors.textTertiary),
                                const SizedBox(height: AppSpacing.xs),
                                Text(
                                  thumb == null ? '画面还没抽出来' : '画面文件不见了',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      fontSize: AppFontSize.micro,
                                      color: AppColors.textTertiary),
                                ),
                              ],
                            ),
                          ),
                        // 悬停时缩略图上盖真视频（有声、循环）
                        if (hovering && !dropped) _hover.buildVideo(),
                        // 角标们
                        Positioned(
                          left: 6,
                          bottom: 6,
                          child: Row(children: [
                            if (material?.durationMs case final ms?)
                              _chip('${(ms / 1000).toStringAsFixed(1)}s'),
                            if (rate != null) ...[
                              const SizedBox(width: 4),
                              _chip(rate, color: AppColors.orange),
                            ],
                          ]),
                        ),
                        if (_previewKeys.contains(key))
                          Positioned(
                              right: 6, top: 6, child: _chip('★ 预览版')),
                        if (dropped)
                          Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: AppSpacing.sm,
                                  vertical: AppSpacing.xs),
                              decoration: BoxDecoration(
                                color: AppColors.red.withValues(alpha: 0.85),
                                borderRadius:
                                    BorderRadius.circular(AppRadius.sm),
                              ),
                              child: const Text('已剔除',
                                  style: TextStyle(
                                      fontSize: AppFontSize.caption,
                                      color: Colors.white)),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.xs),
                  child: Text(
                    material == null
                        ? '素材 ${item.material}'
                        : _tail(material.name),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: AppFontSize.micro,
                        color: AppColors.textTertiary),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }

  Widget _chip(String text, {Color? color}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(AppRadius.xs),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: AppFontSize.micro, color: color ?? Colors.white)),
      );

  static String _tail(String name) =>
      name.length <= 18 ? name : '…${name.substring(name.length - 17)}';

  Widget _confirmBar() => Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        decoration: const BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: SafeArea(
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _error ??
                      '共 ${_items.length} 条 · 保留 '
                          '${_items.length - _droppedCount} · '
                          '剔除 $_droppedCount',
                  style: TextStyle(
                      fontSize: AppFontSize.body,
                      color: _error == null
                          ? AppColors.textSecondary
                          : AppColors.orange),
                ),
              ),
              FilledButton(
                key: const Key('review-confirm'),
                // Agent 正在动这一页时按不得：它下一步就把状态覆盖了
                onPressed: _agent == null ? _confirm : null,
                child: Text(_droppedCount == 0
                    ? '确认 · 全部保留'
                    : '确认 · 剔除 $_droppedCount 条'),
              ),
            ],
          ),
        ),
      );

  /// Agent 正在动这一页：说清它在做什么，以及为什么这会儿改标签和
  /// 「确认」都按不动。
  ///
  /// **两个都要说到**：只解释标签、不解释确认键，人点了确认没反应还是
  /// 会以为软件坏了——那是「点了没反应」的另一种长相。
  ///
  /// 「它在做什么」这一句是可视模式的全部意义——只说「有人在」等于没说。
  ///
  /// **不许在这儿许诺「你能停掉它」**：软件不提供停掉 Agent 的能力，
  /// 人要停它得去 Agent 那头说。这里只说事实：它一收工，入口自己回来。
  Widget _agentBanner(AgentPresence agent) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
        color: AppColors.accentBlue.withValues(alpha: 0.14),
        child: Row(children: [
          const Icon(Icons.smart_toy_outlined,
              size: 16, color: AppColors.accentBlue),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${agent.holder} 正在这一页上干活'
                    '——它动着的时候，改标签和「确认」先按不动，'
                    '免得你改的被它下一次刷新盖掉。它一收工，两个都自己回来',
                    style: const TextStyle(
                        fontSize: AppFontSize.caption,
                        color: AppColors.textSecondary)),
                if (agent.action.isNotEmpty)
                  Text(agent.action,
                      key: const Key('review-agent-action'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: AppFontSize.body,
                          color: AppColors.textPrimary)),
              ],
            ),
          ),
        ]),
      );

  /// Agent 替人点完了几张卡。**必须说清还没落盘**——不说的话人以为完事了，
  /// 关掉窗口就白干
  Widget _delegateBanner(String note) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
        color: AppColors.accentBlue.withValues(alpha: 0.10),
        child: Row(children: [
          const Icon(Icons.smart_toy_outlined,
              size: 16, color: AppColors.accentBlue),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(note,
                key: const Key('review-delegate-note'),
                style: const TextStyle(
                    fontSize: AppFontSize.caption,
                    color: AppColors.textPrimary)),
          ),
          TextButton(
            onPressed: () => setState(() => _delegateNote = null),
            child: const Text('知道了'),
          ),
        ]),
      );

}

/// 审核结果（pop 回来处时带上，来处弹条提示用）
class ReviewOutcome {
  final int kept;
  final int dropped;
  const ReviewOutcome({required this.kept, required this.dropped});
}

/// 换掉某个单元（或它某个镜头）的标签，其余原样返回新列表。
/// 抽成纯函数：改标签是不可变更新，就地改会让 setState 前后指向同一个对象
List<SemanticUnit> _withTags(
    List<SemanticUnit> units, _Section section, List<String> tags) {
  if (section.unitIndex >= units.length) return units;
  return [
    for (var i = 0; i < units.length; i++)
      if (i != section.unitIndex)
        units[i]
      else if (section.shotIndex == null)
        units[i].copyWith(tags: tags)
      else
        units[i].copyWith(shots: [
          for (var j = 0; j < units[i].shots.length; j++)
            if (j == section.shotIndex)
              units[i].shots[j].copyWith(tags: tags)
            else
              units[i].shots[j],
        ]),
  ];
}

class _Section {
  final String id;
  final String title;
  final String transcript;

  /// 这一段落在哪个单元；[shotIndex] 为 null 表示整段替换。
  /// 标签要按这两个下标去任务里取——**取哪一层由替换粒度决定**：
  /// 整段替换检索用的是单元标签，逐镜头替换用的是那个镜头的标签
  final int unitIndex;
  final int? shotIndex;

  /// 镜头替换的固定坑位时长；整段替换为 null（时长跟素材走）
  final int? slotMs;

  /// 「本来的样子」那一段的区间（悬停原片卡播的就是它）。
  /// 空白任务没有原片时为 null
  final int? originStartMs;
  final int? originEndMs;

  /// 这一段取自哪条**素材**（底片固定过的单元）。null = 取自任务原片。
  /// 不记的话原片卡会去原片的同一个时间点抽一段毫不相干的画面，
  /// 而这张卡的用处正是「拿它当参照物比对候选」
  final int? originCandidateId;
  final List<ReviewItem> items;

  _Section({
    required this.id,
    required this.title,
    required this.transcript,
    required this.unitIndex,
    this.shotIndex,
    required this.slotMs,
    this.originStartMs,
    this.originEndMs,
    this.originCandidateId,
    required this.items,
  });
}

class _RailRow extends StatelessWidget {
  final String title;
  final int kept;
  final int total;
  final VoidCallback onTap;

  const _RailRow(
      {required this.title,
      required this.kept,
      required this.total,
      required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: AppSpacing.sm),
          child: Row(
            children: [
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontSize: AppFontSize.caption,
                        color: AppColors.textPrimary)),
              ),
              Text(
                kept == total ? '$total 条' : '$kept/$total',
                style: TextStyle(
                    fontSize: AppFontSize.micro,
                    // 有剔除的位置标橙——一眼看出哪儿动过刀
                    color: kept == total
                        ? AppColors.textTertiary
                        : AppColors.orange),
              ),
            ],
          ),
        ),
      );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => const Center(
        child: Text('这条任务还没有挑过任何候选，没有可审核的。',
            style: TextStyle(color: AppColors.textTertiary)),
      );
}

/// `null + n` 还是 null——底片偏移只对算得出来的那些生效
extension _NullableShift on int? {
  int? plusOrNull(int delta) => this == null ? null : this! + delta;
}
