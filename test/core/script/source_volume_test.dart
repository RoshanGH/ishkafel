import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/script/script_doc.dart';

/// 素材原声该出多大。
///
/// **显示和播放必须是同一个数**——真机 bug：画面行的滑杆显示「静音」
/// （取的是全片基调，默认 0），实际却在满音量播（画面行本来就靠素材出声）。
/// 界面撒谎，人就去拖那根滑杆想「修好」，一拖就把一个显式的 0.0 写死在
/// 那一镜上，从此那一行真的没声了，而且调全片也救不回来。
void main() {
  final visual = ScriptLine.create(text: '').withShots(const [
    LineShot(materialId: 1, name: 'a', durationMs: 9000, allocMs: 4000),
  ]);
  final voiced = ScriptLine.create(text: '第一句').withShots(const [
    LineShot(materialId: 2, name: 'b', durationMs: 9000, allocMs: 4000),
  ]);

  group('视频原声音量（原声要能和配音、配乐一起响）', () {
    test('默认静音：老方案升级后成片声音一个样，不许自己变', () {
      expect(ScriptDoc.empty().sourceVolume, 0.0);
    });

    test('全局调一次，全片的镜头都跟着走', () {
      final doc = ScriptDoc.empty().withSourceVolume(0.3);
      expect(doc.sourceVolume, 0.3);
      const shot = LineShot(materialId: 1, name: 'a');
      expect(doc.sourceVolumeOf(shot), 0.3);
    });

    test('某一镜有音效想单独放大：镜头上的设定压过全局', () {
      final doc = ScriptDoc.empty().withSourceVolume(0.2);
      const shot = LineShot(materialId: 1, name: 'a', sourceVolume: 0.8);
      expect(doc.sourceVolumeOf(shot), 0.8);
    });

    test('某一镜杂音大想单独闭嘴：0 是「静音」，不是「没设过」', () {
      final doc = ScriptDoc.empty().withSourceVolume(0.5);
      const shot = LineShot(materialId: 1, name: 'a', sourceVolume: 0.0);
      expect(doc.sourceVolumeOf(shot), 0.0);
    });

    test('音量越界一律夹回 0~1', () {
      expect(ScriptDoc.empty().withSourceVolume(3).sourceVolume, 1.0);
      expect(ScriptDoc.empty().withSourceVolume(-1).sourceVolume, 0.0);
    });

    test('设回「跟随全局」', () {
      const shot = LineShot(materialId: 1, name: 'a', sourceVolume: 0.8);
      expect(shot.withSourceVolume(null).sourceVolume, isNull);
    });

    test('json 往返：全局与镜头级都不丢', () {
      var doc = ScriptDoc.empty().withSourceVolume(0.35);
      doc = doc.setShotsById(doc.lines.first.id,
          const [LineShot(materialId: 1, name: 'a', sourceVolume: 0.9)]);
      final back = ScriptDoc.fromJson(doc.toJson());
      expect(back.sourceVolume, 0.35);
      expect(back.lines.first.shots.single.sourceVolume, 0.9);
    });

    test('老方案没有这个字段：读出来就是静音，行为跟以前一致', () {
      final back = ScriptDoc.fromJson({
        'lines': [
          {
            'id': 'l1',
            'text': '台词',
            'shots': [
              {'materialId': 1, 'name': 'a'}
            ]
          }
        ]
      });
      expect(back.sourceVolume, 0.0);
      expect(back.lines.first.shots.single.sourceVolume, isNull);
    });
  });

  group('默认值：两种行不一样，但只有一处定义', () {
    test('画面行没配音，本来就靠素材出声——默认满音量', () {
      final doc = ScriptDoc([visual]);
      expect(doc.defaultSourceVolumeFor(visual), 1.0);
      expect(doc.sourceVolumeFor(visual, visual.shots.first), 1.0);
    });

    test('画面行不跟全片基调走：全片调到 0 是为了压住口播下的原声，'
        '不该把整条画面行也弄哑', () {
      final doc = ScriptDoc([visual]).withSourceVolume(0.0);
      expect(doc.sourceVolumeFor(visual, visual.shots.first), 1.0);
    });

    test('配音行默认跟全片基调——原声和口播叠在一起，默认要压住', () {
      final doc = ScriptDoc([voiced]);
      expect(doc.defaultSourceVolumeFor(voiced), 0.0);
      final louder = doc.withSourceVolume(0.3);
      expect(louder.sourceVolumeFor(voiced, voiced.shots.first), 0.3);
    });

    test('逐镜单独设过就以它为准，两种行都一样', () {
      const quiet = LineShot(
          materialId: 1,
          name: 'a',
          durationMs: 9000,
          allocMs: 4000,
          sourceVolume: 0.35);
      final line = ScriptLine.create(text: '').withShots(const [quiet]);
      expect(ScriptDoc([line]).sourceVolumeFor(line, quiet), 0.35);
    });

    test('单独设成 0 就是真静音，不能被默认值顶回去', () {
      const muted = LineShot(
          materialId: 1,
          name: 'a',
          durationMs: 9000,
          allocMs: 4000,
          sourceVolume: 0.0);
      final line = ScriptLine.create(text: '').withShots(const [muted]);
      expect(ScriptDoc([line]).sourceVolumeFor(line, muted), 0.0);
    });
  });
}
