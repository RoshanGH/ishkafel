import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/script/sound_mix.dart';
import 'package:ishkafel/core/subtitle/subtitle_style.dart';

/// 改一样东西，不许把别的东西弄丢。
///
/// 真机上撞的是这个：`withBgmSegments` 构造新文档时只带了 subtitle 和
/// refVideoPath，**漏了 mix、defaultVoiceId、defaultSpeechRate**。于是
/// 「铺一段配乐」顺手把全片音色、语速、三条声轨的音量总控全部重置。
///
/// 人看到的是：编导台顶上写着「本片 · 未定音色」，每一行都是「选择音色」，
/// 可每行又都有精确到 0.1 秒的时长、而且正在导出——
/// **时长来自已经生成好的音频文件，音色标识却没了。**
///
/// 更隐蔽的是 mix：三条轨的音量被悄悄打回默认，成片的声音配比就变了，
/// 而没有任何地方会提示。
///
/// 这类漏字段是手写不可变拷贝的通病，所以这里把每个 with* 都过一遍：
/// 只准动它该动的那一样。
void main() {
  ScriptDoc full() => ScriptDoc(
        [ScriptLine.create(text: '第一句')],
        subtitle: const SubtitleStyle(bottomRatio: 0.31),
        bgmSegments: const [],
        refVideoPath: '/片/原片.mp4',
        mix: const SoundMix(voice: 0.42),
        defaultVoiceId: '小天',
        defaultSpeechRate: 7,
      );

  void expectOthersKept(ScriptDoc next, {String? skip}) {
    if (skip != 'refVideoPath') {
      expect(next.refVideoPath, '/片/原片.mp4', reason: '参考片丢了');
    }
    if (skip != 'defaultVoiceId') {
      expect(next.defaultVoiceId, '小天',
          reason: '全片音色丢了——界面会显示「未定音色」，'
              '而每行明明都有配音；再生成一次还会用错音色');
    }
    if (skip != 'defaultSpeechRate') {
      expect(next.defaultSpeechRate, 7, reason: '全片语速丢了');
    }
    if (skip != 'mix') {
      expect(next.mix.voice, closeTo(0.42, 0.001),
          reason: '三条声轨的音量总控被打回默认——成片的声音配比就变了，'
              '而且没有任何地方会提示');
    }
    if (skip != 'subtitle') {
      expect(next.subtitle.bottomRatio, closeTo(0.31, 0.001), reason: '字幕样式丢了');
    }
  }

  test('铺配乐：只动配乐（真机上正是这一条把音色弄丢的）', () {
    final next = full().withBgmSegments(const []);
    expectOthersKept(next, skip: 'bgmSegments');
  });

  test('换字幕样式：只动字幕', () {
    final next = full().withSubtitle(const SubtitleStyle(bottomRatio: 0.15));
    expect(next.subtitle.bottomRatio, closeTo(0.15, 0.001));
    expectOthersKept(next, skip: 'subtitle');
  });

  test('换声轨总控：只动它', () {
    final next = full().withMix(const SoundMix(voice: 0.9));
    expect(next.mix.voice, closeTo(0.9, 0.001));
    expectOthersKept(next, skip: 'mix');
  });

  test('换全片音色：只动音色', () {
    final next = full().withDefaultVoiceId('小何');
    expect(next.defaultVoiceId, '小何');
    expectOthersKept(next, skip: 'defaultVoiceId');
  });

  test('换全片语速：只动语速', () {
    final next = full().withDefaultSpeechRate(3);
    expect(next.defaultSpeechRate, 3);
    expectOthersKept(next, skip: 'defaultSpeechRate');
  });

  test('改行内容：别的都不许动', () {
    final next = full().insertAfter(0, text: '第二句');
    expect(next.lines.length, 2);
    expectOthersKept(next);
  });

  group('已经被弄坏的档要能自己缓过来', () {
    LineVoiceover vo(String voiceId) => LineVoiceover(
          audioPath: '/vo.mp3',
          durationMs: 1200,
          sourceText: '看到没有',
          voiceId: voiceId,
          speechRate: 0,
          words: const [],
        );

    test('配音清一色同一个音色时，把丢掉的基调认回来', () {
      final json = ScriptDoc([
        ScriptLine.create(text: '看到没有').withVoiceover(vo('vivi')),
        ScriptLine.create(text: '活的').withVoiceover(vo('vivi')),
      ]).toJson()
        ..remove('defaultVoiceId'); // 模拟被铺配乐抹掉
      final healed = ScriptDoc.fromJson(json);
      expect(healed.defaultVoiceId, 'vivi',
          reason: '界面显示「未定音色」而每行都有配音，人一眼就看出不对；'
              '重设一次基调却要白烧 25 句 TTS');
      // 认回来的值和音频一致，所以不该判成过期
      expect(healed.voiceStateOf(healed.lines.first), LineVoiceState.fresh,
          reason: '自愈不能反过来触发重配，那就白救了');
    });

    test('音色本来就混着的：不猜', () {
      final json = ScriptDoc([
        ScriptLine.create(text: '一').withVoiceover(vo('vivi')),
        ScriptLine.create(text: '二').withVoiceover(vo('xiaotian')),
      ]).toJson()
        ..remove('defaultVoiceId');
      expect(ScriptDoc.fromJson(json).defaultVoiceId, isNull,
          reason: '混着的说明本来就是逐行设的，文档级不该替它做主');
    });
  });
}
