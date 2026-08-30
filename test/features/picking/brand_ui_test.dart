import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/replacement/picked_material.dart';
import 'package:ishkafel/features/picking/burned_text_warning.dart';
import 'package:ishkafel/features/picking/picked_tray.dart';

/// 品牌错位是**只有看图才发现得了、而且会毁掉整片**的问题，和烧字同源。
/// 检测出来必须让人看见——存进 json 里没人看等于没做。
void main() {
  /// [ms] 是**当前作用域**里勾着的；[all] 是整条片子挑的全部素材。
  /// 两者不是一回事——品牌冲突是整条片子的事。
  Future<void> pump(WidgetTester tester, List<PickedMaterial> ms,
          {List<PickedMaterial>? all}) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PickedTray(
            items: [for (final m in ms) PickedItem(candidateId: m.id, material: m)],
            allPicked: all ?? ms,
            onRemove: (_) {},
            onSetPreview: (_) {},
          ),
        ),
      ));

  const dettol = PickedMaterial(
      id: 1, name: 'a', burnedText: [], productBrand: '滴露');
  const rove = PickedMaterial(
      id: 2, name: 'b', burnedText: [], productBrand: '若也 Rove');
  const scene = PickedMaterial(id: 3, name: 'c', burnedText: []);
  const dettol2 = PickedMaterial(
      id: 4, name: 'd', burnedText: [], productBrand: '滴露 Dettol');

  testWidgets('品牌打架时，两条都要标出来——人得知道该换哪条', (tester) async {
    await pump(tester, [dettol, rove]);
    expect(find.byKey(const Key('brand-warn-1')), findsOneWidget);
    expect(find.byKey(const Key('brand-warn-2')), findsOneWidget);
  });

  testWidgets('只有一个牌子：不打扰', (tester) async {
    await pump(tester, [dettol, dettol2]);
    expect(find.byKey(const Key('brand-warn-1')), findsNothing);
    expect(find.byKey(const Key('brand-warn-4')), findsNothing);
  });

  /// **品牌冲突是整条片子的事，不是当前这一屏的事**。U1 挑滴露、U3 挑若也，
  /// 站在 U1 的托盘上看只有一个牌子——按当前作用域算的话永远不报警，
  /// 而那正是真实的出错方式：人是一个单元一个单元挑下来的。
  testWidgets('别的单元挑了别家品牌，这一屏也要报', (tester) async {
    await pump(tester, [dettol], all: [dettol, rove]);
    expect(find.byKey(const Key('brand-warn-1')), findsOneWidget);
  });

  testWidgets('纯场景镜头不背这个锅', (tester) async {
    await pump(tester, [dettol, rove, scene]);
    expect(find.byKey(const Key('brand-warn-3')), findsNothing);
  });

  test('胶囊上的话术要说出这条露的是哪个牌子', () {
    final t = brandWarning(rove, conflicting: true)!;
    expect(t, contains('若也 Rove'));
    expect(brandWarning(rove, conflicting: false), isNull);
    expect(brandWarning(scene, conflicting: true), isNull);
  });
}
