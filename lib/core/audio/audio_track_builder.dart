import 'dart:io';

import '../export/composed_timeline.dart';
import '../export/export_commands.dart';
import '../replacement/replacement_plan.dart';
import '../replacement/unit_base.dart';
import '../ffmpeg/process_runner.dart';
import '../ffmpeg/rendered_cache.dart';
import '../log/app_log.dart';
import '../models/semantic_unit.dart';
import 'bgm_cache.dart';
import 'bgm_plan.dart';
import 'material_audio.dart';
import 'overload_check.dart';
import 'source_audio.dart';
import 'vocal_separator.dart';

/// 成片声音的合成器：口播 + 配音 + 配乐，合成一条完整音轨。
///
/// **预览与导出共用这一个类**。分成两套实现的话，用户在工作台里听到的和导出
/// 拿到的迟早会不一样——而预览的全部意义就是「听到的就是要交付的」。
///
/// 三条来源，按段落各取所需：
/// - 换过音色的单元 → 用生成的配音（本来就是纯人声，不含背景）
/// - 被配乐覆盖的镜头 → 用**分离出来的纯人声**（必须去掉原片自带的背景音，
///   否则新配乐与老背景两首曲子一起响）
/// - 其余段落 → 用**原混音**，一个字节都不改
///
/// 最后一条是刻意的：分离是有损的（真机实测，人声轨+背景轨与原混音的残差在
/// -27dB，听得出来）。没换配乐的地方没必要先损一道。
/// 合成结果：落地路径 + 这一次哪几段配乐没铺上。
///
/// 把降级信息**带回来**而不是塞进回调：谁调用谁决定怎么告诉用户（预览是一条
/// 提示条，导出是结果页上的一行），构建器不该猜。
class AudioTrack {
  final String path;

  /// 哪几段配乐没铺上（人话，可直接展示）。为空表示一切正常。
  ///
  /// **预览据此提示、导出据此中止**——同一份信息，两种处置
  final List<String> bgmWarnings;

  /// 哪几层叠上去之后过载了（人话，可直接展示）。
  ///
  /// 各层是**相加**的（用户定的规则，和剪映的时序轴一致），代价就是叠出来
  /// 可能过载。处置方式也是用户定的：**不偷偷压音量躲过去**——那又变成
  /// 软件背着人做判断——而是如实报出来是哪一段，他自己决定调哪一层。
  ///
  /// **和 [bgmWarnings] 不同，这个不中止导出**：片子是合得出来的，只是
  /// 某一段可能听着发破，调不调是人的判断
  final List<String> overloads;

  const AudioTrack({
    required this.path,
    this.bgmWarnings = const [],
    this.overloads = const [],
  });
}

class AudioTrackBuilder {
  final ProcessRunner run;
  final Directory workDir;

  /// 把一条配乐解析成 ffmpeg 能读的地址。
  ///
  /// 缺省用素材自带的 `previewUrl`——那是**带签名的临时地址，隔天就 403**。
  /// 真实装配要注入 [BgmCache]：优先本地缓存、必要时按 id 现取新地址。
  final Future<String> Function(BgmMaterial material)? resolveBgm;

  /// 把一条**替换素材**分离成纯人声，返回人声轨的路径；返回 null 表示分不了
  /// （没装分离工具或分离失败）。
  ///
  /// 为什么需要它：整体替换的段落，声音来自那条素材，里面同样有背景音。
  /// 在它上面铺配乐，素材自带的背景音和新配乐就是两首曲子一起响——跟原片
  /// 那一路是同一个问题，只是音源换成了素材。
  ///
  /// 只在**真的铺了配乐**的段落才调用：分离是有损的（实测残差 -27dB），
  /// 没铺配乐的地方没必要先损一道。
  final Future<String?> Function(String materialPath)? separateMaterial;

  /// 把素材分成人声/背景两路。整体替换选了这两档时用它；
  /// 分不出来就让调用方失败，**不许悄悄换一路声音进成片**
  final Future<SeparatedAudio?> Function(String materialPath)?
      separateMaterialStems;

  /// 导出用的帧率。**声音要和画面按同一个帧率取整**，否则每段差出小半帧、
  /// 一路累积到片尾就是可听见的错位。为 null 表示按默认 30
  final double? exportFps;

  AudioTrackBuilder({
    this.separateMaterial,
    this.separateMaterialStems,
    this.exportFps,
    required this.run,
    required this.workDir,
    this.resolveBgm,
  });

  /// 「原片这一镜的声音」选了某一档，该读哪个文件。
  ///
  /// **分不出来就直接失败，绝不悄悄退回原混音**：人是特意选了「人声」的
  /// （要那句话、不要现场音）。悄悄换一路声音进成片，他得把片子导出来
  /// 听一遍才可能发现，而那时已经交付出去了。
  static String? _sourceTrackFor({
    required MaterialAudioMode mode,
    required String? sourcePath,
    required String? vocalsPath,
    required String? backgroundPath,
    required String where,
  }) {
    switch (mode) {
      case MaterialAudioMode.none:
      case MaterialAudioMode.original:
        return sourcePath;
      case MaterialAudioMode.vocals:
        if (vocalsPath != null && File(vocalsPath).existsSync()) {
          return vocalsPath;
        }
        throw StateError('$where 的原片声音选了「人声」，但这条任务还没有'
            '分离好的人声轨。在工作台上点「重新分离」，'
            '或者跑 ishkafel analyze <任务> 重跑一遍分析；'
            '也可以把它改回「原声」');
      case MaterialAudioMode.background:
        if (backgroundPath != null && File(backgroundPath).existsSync()) {
          return backgroundPath;
        }
        throw StateError('$where 的原片声音选了「背景声」，但这条任务还没有'
            '分离好的背景音轨。在工作台上点「重新分离」，'
            '或者跑 ishkafel analyze <任务> 重跑一遍分析；'
            '也可以把它改回「原声」');
    }
  }

  /// 每一件产物按**内容指纹**命名并复用。没有它的时候，每进一次工作台就要
  /// 把 51 段人声、配乐、拼接、混音整套重跑一遍（真机实测 56 次 ffmpeg），
  /// 而方案一个字都没改
  late final RenderedCache _cache = RenderedCache(dir: workDir, run: run);

  /// 合成整条音轨，返回落地的 WAV 路径。
  ///
  /// [vocalsPath] 是分离出来的纯人声轨；为 null（没装分离工具或分离失败）时，
  /// 被配乐覆盖的段落只能退回原混音——新旧背景会叠在一起，由上层如实告知用户。
  Future<AudioTrack> build({
    /// 原片路径。**为 null 表示空白任务**——那时每个单元都是整体替换，
    /// 声音全部来自素材，不会走到「切原片音频」那一支
    required String? sourcePath,
    required List<SemanticUnit> units,
    String? vocalsPath,
    BgmPlan bgm = BgmPlan.empty,
    Map<String, String> voiceAudio = const {},

    /// 这是第几条导出变体。配乐每一段可以选多首**备选**，按这个序号轮流取
    /// （见 [BgmSegment.materialFor]）。预览传 null，那时用各段的预览版
    int? variantIndex,

    /// 被**整体替换**的单元：单元下标 → 候选素材的本地路径。
    /// 那一段的口播来自候选自己，不再是原片
    Map<int, String> wholeAudio = const {},

    /// 被整体替换的单元在成片里有多长（单元下标 → 毫秒）。配乐的位置要按
    /// 这个换算，否则从被替换的那个单元之后全部错位
    Map<int, int> wholeDurations = const {},

    /// 视觉镜头替换里**要保留原声**的那几镜。上层已经算好了落地路径、
    /// 变速倍率、截取起点和它在成片里的位置——那些参数必须和画面那一段
    /// 用的完全一致，否则声音和画面对不上
    List<ShotMaterialAudio> shotAudio = const [],

    /// 分离出来的纯背景音轨（和 [vocalsPath] 是同一次分离的两条产物）。
    /// 「原片这一镜的声音」选「背景声」时用它；没有就直接失败，
    /// 不许拿原混音顶上
    String? backgroundPath,

    /// 这一条成片里，哪几镜换过素材。「原片这一镜的声音」只对它们生效
    /// （用户原话：「如果没替换分镜，那连原片这一分镜的声音该怎么操作
    /// 都不应该有」）
    Set<(int unitIndex, int shotIndex)> replacedShots = const {},

    /// 「原片这一镜的声音」的全片打底。默认「自动」= 老行为
    SourceAudioSetting sourceAudio = SourceAudioSetting.auto,
  }) async {
    workDir.createSync(recursive: true);
    // 整体替换会改变单元时长，后面所有单元跟着挪——配乐的位置必须按
    // **成片**时间轴算（见 [ComposedTimeline]）
    final timeline =
        ComposedTimeline.of(units: units, wholeDurations: wholeDurations);
    // **按列表下标**，不是原片时间区间——调过序之后后者会指到别的段上
    final covered = bgmCoveredUnits(units, bgm);
    final degraded = <String>[];

    _cache.resetTouched();
    final parts = <String>[];
    for (var i = 0; i < units.length; i++) {
      final unit = units[i];
      parts.addAll(await _unitParts(
        unit: unit,
        listIndex: i,
        sourcePath: sourcePath,
        vocalsPath: vocalsPath,
        backgroundPath: backgroundPath,
        covered: covered,
        voiceAudio: voiceAudio,
        wholeAudio: wholeAudio[unit.index],
        replacedShots: replacedShots,
        sourceAudio: sourceAudio,
      ));
    }

    // 拼接产物由「拼了哪几段」唯一决定
    var key = 'concat|${parts.join('|')}';
    final listFile = _cache.writeText(
        key: key,
        prefix: 'mix_list',
        extension: 'txt',
        content: ExportCommands.concatList(parts));
    var out = await _cache.render(
      key: key,
      prefix: 'mix_voice',
      extension: 'wav',
      args: (dest) => ExportCommands.concat(listFile: listFile, out: dest),
      what: '拼接声音',
    );
    // 叠任何一层之前的样子。过载只看**叠加新添了多少**——原片母带本来就
    // 压到顶，拿绝对峰值当判据等于每条片子都报（见 [AudioLevels.addedClipping]）
    final baseVoice = out;
    /// 叠上去的每一层：叫什么、占成片的哪一段。过载了要能指着说是哪一层
    final layers = <({String label, int startMs, int durationMs})>[];

    // 素材原声逐镜叠上去（视觉镜头替换里开了「保留素材原声」的那些）。
    //
    // 摆在配乐**之前**：配乐是最外面那一层垫底的，先把画面这一段自己的
    // 现场音贴回去，再往整体上铺乐，跟人听到的层次一致。
    //
    // **一镜失败就整条失败**，不像配乐那样只丢一段：用户是特意为这一镜
    // 打开保留原声的（要的就是那个水声、喷雾声），静默少一层他不会发现，
    // 而这是影响成片的东西
    for (final shot in shotAudio) {
      final mixedKey = materialMixKey(
        base: key,
        materialPath: shot.path,
        startMs: shot.composedStartMs,
        durationMs: shot.durationMs,
        speedFactor: shot.speedFactor,
        trimStartMs: shot.trimStartMs,
        volume: shot.volume,
      );
      out = await _cache.render(
        key: mixedKey,
        prefix: 'mix_material',
        extension: 'wav',
        args: (dest) => ExportCommands.mixMaterialAudio(
          voice: out,
          material: shot.path,
          out: dest,
          startMs: shot.composedStartMs,
          durationMs: shot.durationMs,
          speedFactor: shot.speedFactor,
          trimStartMs: shot.trimStartMs,
          volume: shot.volume,
        ),
        what: '这一镜的素材原声',
      );
      key = mixedKey;
      layers.add((
        label: shot.label.isEmpty ? '某一镜的素材原声' : '${shot.label} 的镜头声音',
        startMs: shot.composedStartMs,
        durationMs: shot.durationMs,
      ));
    }

    // 配乐逐段叠上去。段与段之间互不重叠，顺序无所谓。
    //
    // **一段失败只丢那一段，并把原因带回去**：签名地址会过期、网络会断，
    // 而整条音轨作废意味着用户连人声和换过的音色都听不到——真机上就这么
    // 炸过一次，界面只说了句「预览音轨合成失败」，人完全不知道是哪条配乐。
    //
    // 但**只有预览可以这样**：预览时人还在编辑、听得出来。导出拿到
    // [AudioTrack.bgmWarnings] 非空就中止（见 [ExportRunner]）——成片少一段
    // 垫乐是静默的错，交付出去没人会发现。
    for (var i = 0; i < bgm.segments.length; i++) {
      final segment = bgm.segments[i];
      final material = variantIndex == null
          ? segment.previewMaterial
          : segment.materialFor(variantIndex);
      final range =
          timeline.rangeOfUnits(segment.startUnit, segment.endUnit);
      if (range == null) {
        AppLog.warn('配乐「${material.name}」找不到对应的镜头范围，这一段跳过');
        continue;
      }
      final String source;
      try {
        source = await _resolve(material);
      } catch (e) {
        // 底层已经把原因说成人话了，不要再套一层——真机上套出来的那句
        // 「配乐「X」这次取不到（配乐「X」下下来是坏的…）」曲名重复、长得没法读。
        // 但也不能假设它一定带了曲名：没提到就补一次，提到了就原样用
        final raw = e is BgmUnavailableException ? e.message : '$e';
        final name = material.name;
        final message = raw.contains(name) ? raw : '配乐「$name」：$raw';
        AppLog.warn('配乐取不到：$message');
        degraded.add(message);
        continue;
      }
      // 叠配乐是链式的：这一段的内容由「上一层是什么 + 这一段铺的是谁」决定
      final mixedKey = bgmMixKey(
        base: key,
        materialId: material.id,
        startMs: range.$1,
        endMs: range.$2,
        volume: segment.volume,
      );
      final String mixed;
      try {
        mixed = await _cache.render(
          key: mixedKey,
          prefix: 'mix_bgm',
          extension: 'wav',
          args: (dest) => ExportCommands.mixBgm(
            voice: out,
            bgm: source,
            out: dest,
            startMs: range.$1,
            durationMs: range.$2 - range.$1,
            // 每段自己的音量（见 [BgmSegment.volume]）——预览和导出走同一条路，
            // 这里改了两边一起变
            bgmVolume: segment.volume,
          ),
          what: '配乐「${material.name}」',
        );
      } catch (e) {
        final message = '配乐「${material.name}」这一段没铺上：$e';
        AppLog.warn(message);
        degraded.add(message);
        continue;
      }
      out = mixed;
      key = mixedKey;
      layers.add((
        label: '配乐「${material.name}」',
        startMs: range.$1,
        durationMs: range.$2 - range.$1,
      ));
    }
    // 指纹命名意味着换一次方案就多攒一套，不清就只增不减
    _cache.keepOnly();
    return AudioTrack(
      path: out,
      bgmWarnings: List.unmodifiable(degraded),
      overloads: List.unmodifiable(
          await _overloads(base: baseVoice, mixed: out, layers: layers)),
    );
  }

  /// 叠出来过载的是哪几层。一层都没叠时**连量都不用量**。
  ///
  /// 分两步走是为了不做白花的活：先整条量一次（两次 ffmpeg），确认叠加真的
  /// 新添了可听见的过载，才逐层去量各自那一小段。过载是例外，绝大多数导出
  /// 只多花那两次
  Future<List<String>> _overloads({
    required String base,
    required String mixed,
    required List<({String label, int startMs, int durationMs})> layers,
  }) async {
    if (layers.isEmpty || base == mixed) return const [];
    if (!AudioLevels.addedClipping(
        base: await _levelsOf(base), mixed: await _levelsOf(mixed))) {
      return const [];
    }
    final named = <String>[];
    for (final layer in layers) {
      final before = await _levelsOf(base,
          fromMs: layer.startMs, durationMs: layer.durationMs);
      final after = await _levelsOf(mixed,
          fromMs: layer.startMs, durationMs: layer.durationMs);
      if (AudioLevels.addedClipping(base: before, mixed: after)) {
        named.add('${layer.label}叠上去之后这一段过载了，听着会发破——'
            '把它的音量调小一点');
      }
    }
    // 整条量出来有过载、却落不到具体某一层（几层各自都不过分、加在一起才过）
    // ：也要说，只是说不出是哪一层
    if (named.isEmpty) {
      named.add('几层声音加在一起有一段过载了，听着会发破——'
          '把镜头声音或配乐的音量调小一点');
    }
    return named;
  }

  /// 量一段声音的电平。量不到就返回 null——**不许猜**，猜出来的警告比不报更糟
  Future<AudioLevels?> _levelsOf(String path,
      {int? fromMs, int? durationMs}) async {
    try {
      final result = await run(
          'ffmpeg',
          ExportCommands.measureLevels(
              input: path, fromMs: fromMs, durationMs: durationMs));
      return AudioLevels.parse('${result.stderr}');
    } catch (e) {
      AppLog.warn('量不到电平（$path）：$e');
      return null;
    }
  }

  /// 「这一镜的素材原声叠上去」这件产物的指纹。
  ///
  /// **规则版本要在里面**（见 [ExportCommands.mixRuleVersion]）：只拼入参的话，
  /// 改了滤镜链也命中旧产物，用户装了新版重新导出听到的还是老毛病
  static String materialMixKey({
    required String base,
    required String materialPath,
    required int startMs,
    required int durationMs,
    required double speedFactor,
    required int? trimStartMs,
    required double volume,
    String? version,
  }) =>
      'mataudio|${version ?? ExportCommands.mixRuleVersion}|$base'
      '|$materialPath|$startMs|$durationMs|$speedFactor|$trimStartMs|$volume';

  /// 「这一段配乐铺上去」这件产物的指纹。同样要带规则版本
  static String bgmMixKey({
    required String base,
    required int materialId,
    required int startMs,
    required int endMs,
    required double volume,
    String? version,
  }) =>
      'bgm|${version ?? ExportCommands.mixRuleVersion}|$base'
      '|$materialId|$startMs|$endMs|$volume';

  /// 缺省退回素材自带地址——它随时可能已经失效，所以真实装配一定要注入
  /// [resolveBgm]
  Future<String> _resolve(BgmMaterial material) async {
    final resolver = resolveBgm;
    if (resolver != null) return resolver(material);
    final url = material.previewUrl;
    if (url == null || url.isEmpty) {
      throw StateError('没有可用地址');
    }
    return url;
  }

  /// 一个单元切出来的若干段声音。
  ///
  /// 换过音色的单元整段用配音；否则按**镜头**切。
  ///
  /// [covered] 是被配乐盖住的**列表下标**集合。配乐按整格单元铺
  /// （`startUnit..endUnit`），所以一个单元要么整格被盖、要么整格没被盖。
  Future<List<String>> _unitParts({
    required SemanticUnit unit,
    required int listIndex,
    required String? sourcePath,
    required String? vocalsPath,
    required String? backgroundPath,
    required Set<int> covered,
    required Map<String, String> voiceAudio,

    /// 这个单元被整体替换了：口播来自这条候选素材，整段取用不裁不补
    String? wholeAudio,

    /// 这条成片里换过素材的那几镜，和「原片这一镜的声音」的全片打底
    Set<(int unitIndex, int shotIndex)> replacedShots = const {},
    SourceAudioSetting sourceAudio = SourceAudioSetting.auto,
  }) async {
    // 整体替换优先于换音色——同一个单元两者都设时导出前置检查已经拦下了
    if (wholeAudio != null && File(wholeAudio).existsSync()) {
      final setting = resolveWholeAudio(unit);
      // 明确要求这一段别出声（片头插的空镜常这么用：只要画面，声音交给配乐）
      if (!setting.mode.audible) return const [];

      var source = wholeAudio;
      // 选了人声/背景声：按档位取那一路。**分不出来就失败，不悄悄换一路**
      if (setting.mode.needsSeparation) {
        final stems = await separateMaterialStems?.call(wholeAudio);
        if (stems == null) {
          throw StateError('U${unit.index + 1} 选了「${setting.mode.label}」，'
              '但这条素材分离失败。重试一次，或把它改成「原声」/「不播放」');
        }
        source = setting.mode == MaterialAudioMode.vocals
            ? stems.vocalsPath
            : stems.backgroundPath;
      } else if (covered.contains(listIndex)) {
        // 这一段被配乐盖住时，用素材的**纯人声**：素材自带的背景音留着的话，
        // 它和新配乐就是两首曲子一起响
        final vocals = await separateMaterial?.call(wholeAudio);
        if (vocals != null && File(vocals).existsSync()) source = vocals;
      }
      return [
        await _cache.render(
          // 音量进指纹：改了音量要重渲，不能命中上一次那份
          key: 'whole|$source|${setting.volume}',
          prefix: 'mix_u${unit.index}_whole',
          extension: 'wav',
          args: (dest) => ExportCommands.wholeReplacementAudio(
              input: source, out: dest, volume: setting.volume),
          what: 'U${unit.index + 1} 的替换声音',
        )
      ];
    }

    // 按单元的**身份**取：按位置取的话，人挪过顺序之后念的是别人那段
    final voice = voiceAudio[unit.uid];
    if (voice != null && File(voice).existsSync()) {
      return [
        await _cache.render(
          // fps 进键：-t 是按帧取整算的，30fps 与 60fps 的产物不同
          key: 'voice|$voice|${unit.durationMs}|$exportFps',
          prefix: 'mix_u${unit.index}_voice',
          extension: 'wav',
          args: (dest) => ExportCommands.fitVoiceAudio(
              input: voice,
              durationMs: unit.durationMs,
              out: dest,
              atFps: exportFps),
          what: 'U${unit.index + 1} 的配音',
        )
      ];
    }

    final pieces = <String>[];
    final ranges = unit.shots.isEmpty
        ? [(unit.startMs, unit.endMs)]
        : [for (final s in unit.shots) (s.startMs, s.endMs)];
    for (var i = 0; i < ranges.length; i++) {
      final (start, end) = ranges[i];
      final shotIndex = unit.shots.isEmpty ? -1 : i;
      // 人**明确选过**这一镜放哪一路原片声音吗（只有换过素材的镜头才可能）
      final picked = resolveSourceAudio(
        replaced: replacedShots.contains((unit.index, shotIndex)),
        taskDefault: sourceAudio,
        shotMode: shotIndex < 0 ? null : unit.shots[shotIndex].sourceAudioMode,
        shotVolume:
            shotIndex < 0 ? null : unit.shots[shotIndex].sourceAudioVolume,
      );

      // 明确要求这一镜不放原片的声音：**垫等长静音**，不能少拼一段——
      // 主轨是首尾相接拼起来的，少一段后面全体提前
      if (picked != null && !picked.mode!.audible) {
        pieces.add(await _cache.render(
          key: 'silent|${end - start}|$exportFps',
          prefix: 'mix_u${unit.index}_${i}_mute',
          extension: 'wav',
          args: (dest) => ExportCommands.silentAudio(
              durationMs: end - start, out: dest, atFps: exportFps),
          what: 'U${unit.index + 1} 的静音段',
        ));
        continue;
      }

      // 被配乐盖住的段落必须用纯人声，否则老背景与新配乐一起响
      // 配乐按整格单元铺，所以这一格里每一镜的答案都一样。
      // **人选过就以人选的为准**——冲突只提示，不替他改（那是静默降级）
      final needsClean =
          picked == null && covered.contains(listIndex) && vocalsPath != null;
      // **手动加的单元不许去原片上剪**：它的 startMs~endMs 只是时间线上的
      // 占位，原片里没有这一段。不挡住的话会剪出一段别的声音接进成片，
      // 而且哪儿都不报错——人只有听出来才知道。
      //
      // 判据走[baseChoiceOf]，跟画面同一份规则：声音和画面对同一个单元
      // 给出不同答案，就是一边有声一边黑屏。这里问的是「底片是原片吗」
      // ——整体替换（底片是素材）在本方法开头就已经处理掉了，所以传
      // keepOriginal
      final hasBase = baseChoiceOf(
            unit: unit,
            replacement: UnitReplacement.keepOriginal(),
            hasOriginal: sourcePath != null,
          ) is OriginalBase;
      final source = !hasBase
          ? null
          : picked != null
              ? _sourceTrackFor(
                  mode: picked.mode!,
                  sourcePath: sourcePath,
                  vocalsPath: vocalsPath,
                  backgroundPath: backgroundPath,
                  where: 'U${unit.index + 1}'
                      '${shotIndex < 0 ? '' : ' 的 S${shotIndex + 1}'}',
                )
              : (needsClean ? vocalsPath : sourcePath);
      if (source == null) {
        // 空白任务里每个单元都是整体替换，走不到这儿。走到了就是有一段
        // 既没有素材也没有原片——不许拿静音顶上，那会让成片少一段声音
        throw StateError('U${unit.index + 1} 这一段既没有素材也没有原片，'
            '合不出声音。请给它挑一条素材，或者删掉它');
      }
      final volume = picked?.volume ?? 1.0;
      pieces.add(await _cache.render(
        // 音量进指纹：改了音量要重渲，不能命中上一次那份
        key: 'trim|$source|$start|$end|$exportFps|$volume',
        prefix: 'mix_u${unit.index}_$i${needsClean ? '_v' : ''}',
        extension: 'wav',
        args: (dest) => ExportCommands.trimOriginalAudio(
          source: source,
          startMs: start,
          endMs: end,
          out: dest,
          atFps: exportFps,
          volume: volume,
        ),
        what: 'U${unit.index + 1} 的声音',
      ));
    }
    return pieces;
  }

  /// 哪几格被配乐盖住了——**给的是列表下标，不是原片时间区间**。
  ///
  /// 配乐本来就按单元下标记（`startUnit..endUnit`）。原来是拿这两个下标去取
  /// `units[i].startMs/endMs` 拼一个原片时间区间，再和每一镜的原片区间比重叠：
  /// 列表顺序和原片顺序一致时恰好对，一调序就指到别的段上，甚至首尾颠倒
  /// （起点的原片时间比终点还晚），于是谁都不命中。
  ///
  /// 后果是这一段该用**纯人声**还是**原片原声（含背景音）**判反：老背景和新
  /// 配乐一起响，或者背景音凭空消失。用户原话：「我把 U1 换到其他位置上……
  /// 它的背景音乐就会出问题……放回原来的位置之后就恢复了」（2026-09-08 真机）。
  ///
  /// 配乐盖的是整格单元，所以下标粒度**正好够**，不需要再退到毫秒。
  static Set<int> bgmCoveredUnits(List<SemanticUnit> units, BgmPlan bgm) {
    if (units.isEmpty) return const {};
    final out = <int>{};
    for (final segment in bgm.segments) {
      if (segment.startUnit < 0 || segment.startUnit >= units.length) continue;
      final end = segment.endUnit.clamp(segment.startUnit, units.length - 1);
      for (var i = segment.startUnit; i <= end; i++) {
        out.add(i);
      }
    }
    return out;
  }
}
