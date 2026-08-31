import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/voice_baseline.dart';
import 'package:ishkafel/core/script/script_doc.dart';

/// 这一批配音用哪个音色当基调。
///
/// 界面早就写对了，还留了注释「拿目录里第一个撞运气去配 27 句，不对就白烧
/// 一轮 TTS（真机上就是这么浪费掉的）」，于是它在生成前先卡住让人选。
/// **CLI 这边 `doc.defaultVoiceId` 看都不看**，直接拿目录里第一个去配
/// ——同一笔钱又烧了一遍，这次是验收 Agent 烧的：它先 `apply baseline`
/// 设了「小天」，CLI 无视，用女声配完 25 句；它发现不对，显式写 25 行
/// 再配一轮。两轮 50 句 TTS，全是白花的。
///
/// 更坏的是配完还把那个错音色**固化写进每一行**，于是看起来像
/// 「提取时预填了女声」——排查方向整个被带偏。
void main() {
  ScriptDoc docWith({String? defaultVoice, String? lineVoice}) {
    var line = ScriptLine.create(text: '早就跟你们说了');
    if (lineVoice != null) line = line.withVoiceId(lineVoice);
    var doc = ScriptDoc([line]);
    if (defaultVoice != null) doc = doc.withDefaultVoiceId(defaultVoice);
    return doc;
  }

  test('命令行显式给的音色最大', () {
    final r = resolveVoiceBaseline(
        doc: docWith(defaultVoice: '小天'), explicit: '小美');
    expect(r.voiceId, '小美');
    expect(r.reject, isNull);
  });

  test('apply baseline 设的全片基调要认——这一条当初整个漏了', () {
    final r = resolveVoiceBaseline(doc: docWith(defaultVoice: '小天'));
    expect(r.voiceId, '小天',
        reason: '人明明定了基调，CLI 却拿目录里第一个去配，'
            '整批配音全是错音色，钱照花');
  });

  test('基调没设但行上设过：跟着行走', () {
    final r = resolveVoiceBaseline(doc: docWith(lineVoice: '小美'));
    expect(r.voiceId, '小美');
  });

  test('基调优先于行——行上那个多半是上一轮固化进去的', () {
    final r = resolveVoiceBaseline(
        doc: docWith(defaultVoice: '小天', lineVoice: '小美'));
    expect(r.voiceId, '小天');
  });

  test('三级都没有：不许撞运气，拒绝并说清怎么定', () {
    final r = resolveVoiceBaseline(doc: docWith());
    expect(r.voiceId, isNull);
    expect(r.reject, isNotNull,
        reason: '音色错了整片废、且是花钱的一步——这是不该静默降级的那一类');
    expect(r.reject, contains('voices'),
        reason: '拒绝要给能照做的下一步：先看有哪些音色');
    expect(r.reject, anyOf(contains('--voice'), contains('baseline')),
        reason: '还要说清怎么把音色定下来');
  });
}
