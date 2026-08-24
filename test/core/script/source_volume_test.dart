import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/script/script_doc.dart';

void main() {
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
}
