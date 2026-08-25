import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/playback/track_plan.dart';
import 'package:ishkafel/core/script/script_track_plan.dart';

/// 整片预览轨：只拼就绪的行、跳过必点名、画面轨连续、配音随行铺。
LineVoiceover vo(int ms) => LineVoiceover(
    audioPath: '/vo.mp3',
    durationMs: ms,
    sourceText: '词',
    voiceId: 'v',
    speechRate: 0);

LineShot shot(int id, {int? alloc, int trim = 0, double speed = 1.0}) =>
    LineShot(
        materialId: id,
        name: 's$id',
        durationMs: 10000,
        allocMs: alloc,
        trimStartMs: trim,
        speed: speed);

void main() {
  test('三路声音各司其职：口播轨只放配音，素材原声走原声轨', () {
    // 真机踩过的坑：把素材原声塞进画面轨或口播轨，等于让这条轨上出现
    // 「有音轨/无音轨」「24kHz 单声道/48kHz 立体声」的接缝——播放器
    // 到接缝处要重搭音频链路，主时钟当场卡死，一个词反复念十几遍
    final doc = ScriptDoc([
      ScriptLine.create(text: '第一句')
          .withShots(const [
            LineShot(materialId: 1, name: 'a', durationMs: 9000, allocMs: 4000),
          ])
          .withVoiceover(vo(4000)),
    ]).withSourceVolume(0.35);
    final result = buildScriptTrackPlan(doc,
        sourceOf: (s) => ShotSource('/m/${s.materialId}.mp4'),
        voiceSegmentOf: ({
          required kind,
          required source,
          required inMs,
          required durationMs,
          required speed,
        }) =>
            '/norm/$kind-$durationMs.mp3');

    expect(result.plan.voice.single.source, '/norm/voice-4000.mp3',
        reason: '口播轨拿的是**规范化后**的配音段——统一规格才没有接缝');
    expect(result.plan.video.single.volume, 0.35,
        reason: '素材原声的音量挂在画面段上，由原声轨按段取用');
  });

  test('画面行：口播轨垫同规格静音，声音走原声轨且逐镜音量生效', () {
    final doc = ScriptDoc([
      ScriptLine.create(text: '')
          .withManualMs(15000)
          .withShots(const [
        LineShot(
            materialId: 7,
            name: '外壳',
            durationMs: 20000,
            allocMs: 15000,
            sourceVolume: 0.35),
      ]),
    ]);
    final result = buildScriptTrackPlan(doc,
        sourceOf: (s) => ShotSource('/m/${s.materialId}.mp4'),
        voiceSegmentOf: ({
          required kind,
          required source,
          required inMs,
          required durationMs,
          required speed,
        }) =>
            '/norm/$kind-$durationMs.mp3');

    expect(result.plan.voice.single.source, '/norm/mute-15000.mp3',
        reason: '画面行没有配音，但口播轨不能留空档——EDL 会把空档压掉');
    expect(result.plan.video.single.volume, 0.35,
        reason: '这一镜单独调的原声音量要能生效（真机反馈：调了没反应）');
  });

  test('声音段还没准备好：这一行先不进预览，并说清在等什么', () {
    final doc = ScriptDoc([
      ScriptLine.create(text: '第一句')
          .withShots(const [
            LineShot(materialId: 1, name: 'a', durationMs: 9000, allocMs: 4000),
          ])
          .withVoiceover(vo(4000)),
    ]);
    // 规范化器在，但这一段还在渲（返回 null）
    final result = buildScriptTrackPlan(doc,
        sourceOf: (s) => ShotSource('/m/${s.materialId}.mp4'),
        voiceSegmentOf: ({
          required kind,
          required source,
          required inMs,
          required durationMs,
          required speed,
        }) =>
            null);
    expect(result.plan.video, isEmpty);
    expect(result.skippedLines[0], contains('声音还在准备'));
  });

  test('画面铺不满坑位：整行拦下不进预览，并说清差多少、该怎么办', () {
    // 真机：这条素材只有 1.2 秒却被分了 6 秒（时长探测失败当成了无限长）。
    // 让它进预览会两头出错——画面轨缩水、配音被反复拽回同一处（听起来
    // 就是台词一直重复）。所以这是阻断性的：宁可这一行不播，也不能播错
    final doc = ScriptDoc([
      ScriptLine.create(text: '现在我们家每个月都有定期清理冰箱的好习惯')
          .withShots(const [
            LineShot(
                materialId: 106720,
                name: '滴露冰箱',
                durationMs: 1207,
                allocMs: 6048),
          ])
          .withVoiceover(LineVoiceover(
              audioPath: '/vo.mp3',
              durationMs: 6048,
              sourceText: '现在我们家每个月都有定期清理冰箱的好习惯',
              voiceId: 'v',
              speechRate: 0)),
    ]);
    final result = buildScriptTrackPlan(doc,
        sourceOf: (shot) => const ShotSource('/m/106720.mp4'));

    expect(result.plan.video, isEmpty, reason: '铺不满就不进预览');
    expect(result.skippedLines[0], contains('画面'));
    expect(result.skippedLines[0], contains('4.8'),
        reason: '差多少要说出来，不然人不知道要调多少');
  });

  test('两行就绪：画面轨连续相接、配音各铺各行、总长正确', () {
    var doc = ScriptDoc.empty().updateText(0, '第一句');
    doc = doc.insertAfter(0, text: '第二句');
    doc = doc
        .setVoiceoverById(doc.lines[0].id, vo(4000))
        .setVoiceoverById(doc.lines[1].id, vo(3000));
    doc = doc
        .setShotsById(doc.lines[0].id, [shot(1, alloc: 2000, trim: 500), shot(2, alloc: 2000)])
        .setShotsById(doc.lines[1].id, [shot(3, alloc: 3000)]);

    final result = buildScriptTrackPlan(doc,
        sourceOf: (s) => ShotSource('/m/${s.materialId}.mp4', inMs: s.trimStartMs));

    expect(result.skippedLines, isEmpty);
    final v = result.plan.video;
    expect(v.map((s) => s.atMs), [0, 2000, 4000], reason: '画面轨连续无洞');
    expect(v[0].inMs, 500, reason: '框选起点要带进段里');
    expect(result.plan.voice.map((s) => (s.atMs, s.durationMs)),
        [(0, 4000), (4000, 3000)]);
    expect(result.plan.totalMs, 7000);
  });

  test('没配音/没镜头/没分配/素材未就绪的行被跳过并各自点名', () {
    var doc = ScriptDoc.empty().updateText(0, '没配音');
    doc = doc.insertAfter(0, text: '没镜头');
    doc = doc.insertAfter(1, text: '没分配');
    doc = doc.insertAfter(2, text: '没素材');
    doc = doc
        .setVoiceoverById(doc.lines[1].id, vo(2000))
        .setVoiceoverById(doc.lines[2].id, vo(2000))
        .setVoiceoverById(doc.lines[3].id, vo(2000));
    doc = doc
        .setShotsById(doc.lines[2].id, [shot(1)])
        .setShotsById(doc.lines[3].id, [shot(2, alloc: 2000)]);

    final result = buildScriptTrackPlan(doc,
        sourceOf: (s) => s.materialId == 2 ? null : ShotSource('/m.mp4'));

    expect(result.plan.isEmpty, isTrue);
    expect(result.skippedLines[0], contains('配音'));
    expect(result.skippedLines[1], contains('镜头'));
    expect(result.skippedLines[2], contains('分时长'));
    expect(result.skippedLines[3], contains('素材'));
  });

  test('纯空行不进预览也不点名（它什么都还不是）', () {
    final doc = ScriptDoc.empty();
    final result = buildScriptTrackPlan(doc, sourceOf: (_) => null);
    expect(result.plan.isEmpty, isTrue);
    expect(result.skippedLines, isEmpty);
  });

  test('分配不足根时配音随画面截断（缺口另有警告，预览如实反映）', () {
    var doc = ScriptDoc.empty().updateText(0, '词');
    doc = doc.setVoiceoverById(doc.lines[0].id, vo(6000));
    doc = doc.setShotsById(doc.lines[0].id, [shot(1, alloc: 4000)]);

    final result =
        buildScriptTrackPlan(doc, sourceOf: (_) => const ShotSource('/m.mp4'));

    expect(result.plan.video.single.durationMs, 4000);
    expect(result.plan.voice.single.durationMs, 4000,
        reason: '配音只铺到画面结束，不悬空');
  });

  test('画面行（无台词）：画面轨 + 素材自己的原声，没有配音段', () {
    var doc = ScriptDoc.empty(); // 空行 = 画面行
    doc = doc.setManualMs(0, 3000);
    doc = doc.setShotsById(doc.lines[0].id, [shot(1, alloc: 3000)]);

    final result =
        buildScriptTrackPlan(doc, sourceOf: (_) => const ShotSource('/m.mp4'));

    expect(result.plan.video, hasLength(1));
    expect(result.plan.voice, hasLength(1),
        reason: '画面行用素材自己的声音（设计稿：或用分镜自己的声音）');
    expect(result.plan.voice.single.source, '/m.mp4');
  });
}
