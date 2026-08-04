import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/models/tag_group_ref.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/features/picking/picking_controller.dart';
import 'package:ishkafel/features/picking/picking_scope.dart';
import 'package:ishkafel/features/picking/tag_id_resolver.dart';

/// 两层各一套标签：画面层 11/12，台词语义层 21/22
class _Tags implements MiaoaTagService {
  @override
  Future<List<TagInfo>> listTags(int groupId) async => switch (groupId) {
        1 => const [TagInfo(id: 11, name: '近景'), TagInfo(id: 12, name: '中景')],
        2 => const [TagInfo(id: 21, name: '促单'), TagInfo(id: 22, name: '辅助卖点')],
        _ => const [],
      };

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _unitGroups = [TagGroupRef(id: 2, name: '植源分子库')];
const _shotGroups = [TagGroupRef(id: 1, name: '植源场景')];

List<SemanticUnit> _units() => const [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 4000,
        transcript: '再不买就恢复六十九块九了',
        tags: ['促单', '辅助卖点'],
        shots: [
          Shot(startMs: 0, endMs: 1000, tags: ['近景'], description: '手持产品特写'),
          Shot(startMs: 1000, endMs: 4000, tags: ['中景'], description: '主播在厨房讲解'),
        ],
      ),
    ];

Future<PickingScope> _scope({
  required ReplacementMode mode,
  int? shotIndex,
  List<SemanticUnit>? units,
}) async {
  final picking = PickingController(units: units ?? _units());
  picking.selectUnit(0);
  // 先切模式再选镜头：setMode(perShot) 会把选中镜头复位到 0
  picking.setMode(mode);
  picking.selectShot(shotIndex);
  final resolver = TagIdResolver(_Tags());
  await resolver.loadAll([1, 2]);
  return PickingScope.from(
    picking: picking,
    resolver: resolver,
    shotTagGroups: _shotGroups,
    unitTagGroups: _unitGroups,
  );
}

void main() {
  group('整体替换：用这个台词语义单元自己的标签', () {
    test('检索键是单元的标签，不是它那几个镜头标签的并集', () async {
      final scope = await _scope(mode: ReplacementMode.whole);

      expect(scope.tagNames, ['促单', '辅助卖点']);
      expect(scope.tagIds, [21, 22],
          reason: '一个单元七八个镜头就是十几个标签，'
              '再按「任一满足」搜等于把半个素材库都捞回来');
    });

    test('不做画面描述检索', () async {
      final scope = await _scope(mode: ReplacementMode.whole);

      expect(scope.descriptionSupported, isFalse,
          reason: '画面描述是对单个镜头生成的一句话；'
              '一整句台词对应一串镜头，没有一句能代表它们');
      expect(scope.descriptionKeyword, isEmpty);
    });

    test('时长基准是整个单元', () async {
      final scope = await _scope(mode: ReplacementMode.whole);

      expect(scope.targetDurationMs, 4000);
    });

    test('单元没打上标签时说清是哪一层，别让用户去改另一层', () async {
      final scope = await _scope(
        mode: ReplacementMode.whole,
        units: const [
          SemanticUnit(
            index: 0,
            startMs: 0,
            endMs: 4000,
            transcript: '台词',
            shots: [Shot(startMs: 0, endMs: 4000, tags: ['近景'])],
          ),
        ],
      );

      expect(scope.tagUnavailableText, contains('台词语义单元'));
    });
  });

  group('镜头替换：用选中那个镜头自己的东西', () {
    test('检索键是这个镜头的标签', () async {
      final scope = await _scope(mode: ReplacementMode.perShot, shotIndex: 1);

      expect(scope.tagIds, [12]);
      expect(scope.targetDurationMs, 3000);
    });

    test('画面描述用的是这个镜头的画面描述，不是台词', () async {
      final scope = await _scope(mode: ReplacementMode.perShot, shotIndex: 1);

      expect(scope.descriptionSupported, isTrue);
      expect(scope.descriptionKeyword, '主播在厨房讲解',
          reason: '拿台词原文去搜，搜的是「话术像不像」，'
              '而库里那一栏写的是「画面里有什么」，本就对不上');
    });

    test('换一个镜头，描述也跟着换', () async {
      final scope = await _scope(mode: ReplacementMode.perShot, shotIndex: 0);

      expect(scope.descriptionKeyword, '手持产品特写');
    });
  });
}
