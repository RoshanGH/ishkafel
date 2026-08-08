import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/replacement/picked_material.dart';

RenewTask _task({List<PickedMaterial> picked = const []}) => RenewTask(
      id: 't1',
      name: '任务',
      sourcePath: '/v/a.mp4',
      status: RenewTaskStatus.ready,
      createdAt: DateTime(2026, 8, 7),
      updatedAt: DateTime(2026, 8, 7),
      pickedMaterials: picked,
    );

void main() {
  group('已选素材落地', () {
    test('存盘再读出来，名字/台词/时长/首帧图路径都还在', () {
      final task = _task(picked: [
        const PickedMaterial(
          id: 100,
          name: '素材A',
          voiceover: '这条素材原本在说什么',
          sceneDescription: '厨房里擦台面',
          thumbPath: '/local/100.jpg',
          durationMs: 5200,
        ),
      ]);

      final back = RenewTask.fromJson(task.toJson());

      expect(back.pickedMaterials.single.id, 100);
      expect(back.pickedMaterials.single.voiceover, '这条素材原本在说什么');
      expect(back.pickedMaterials.single.thumbPath, '/local/100.jpg');
      expect(back.pickedMaterials.single.durationMs, 5200);
    });

    test('老任务没有这一段时读出来是空的，不炸', () {
      final json = _task().toJson()..remove('pickedMaterials');

      expect(RenewTask.fromJson(json).pickedMaterials, isEmpty);
    });

    test('畸形的那一条跳过，不牵连整份任务', () {
      final json = _task().toJson()
        ..['pickedMaterials'] = [
          {'id': 1, 'name': '好的'},
          {'name': '没有 id'},
          '这根本不是对象',
        ];

      expect(RenewTask.fromJson(json).pickedMaterials.map((m) => m.id), [1]);
    });

    test('托盘显示什么：台词 → 画面描述 → 素材名', () {
      expect(
          const PickedMaterial(id: 1, name: 'N', voiceover: 'V', sceneDescription: 'S')
              .label,
          'V');
      expect(const PickedMaterial(id: 1, name: 'N', sceneDescription: 'S').label, 'S');
      expect(const PickedMaterial(id: 1, name: 'N').label, 'N');
    });
  });
}
