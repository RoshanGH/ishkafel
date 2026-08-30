import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/replacement/picked_material.dart';
import 'package:ishkafel/features/picking/burned_text_warning.dart';
import 'package:ishkafel/features/picking/picked_tray.dart';

/// 检测出来的结果**必须让人看见**。存进 json 里没人看，等于没做——
/// 用户是在托盘上核对「我选的这几条」的，警告就得出现在那儿。
void main() {
  Future<void> pump(WidgetTester tester, PickedMaterial m) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PickedTray(
              items: [PickedItem(candidateId: 1, material: m)],
              onRemove: (_) {},
              onSetPreview: (_) {},
            ),
          ),
        ),
      );

  const clean = PickedMaterial(id: 1, name: '素材', burnedText: []);
  const dirty =
      PickedMaterial(id: 1, name: '素材', burnedText: ['冰冰凉凉的好舒服呀']);
  const unchecked = PickedMaterial(id: 1, name: '素材');

  testWidgets('画面烧着字：托盘上必须有警告', (tester) async {
    await pump(tester, dirty);
    expect(find.byKey(const Key('burned-warn-1')), findsOneWidget);
  });

  testWidgets('画面干净：不打扰', (tester) async {
    await pump(tester, clean);
    expect(find.byKey(const Key('burned-warn-1')), findsNothing);
  });

  testWidgets('没查过：也不打扰托盘，但话术上区分得开', (tester) async {
    await pump(tester, unchecked);
    expect(find.byKey(const Key('burned-warn-1')), findsNothing);
  });

  test('警告文案要把烧的字原样说出来，并说清后果', () {
    final text = burnedTextWarning(dirty)!;
    expect(text, contains('冰冰凉凉的好舒服呀'));
    expect(text, contains('字幕'));
    expect(burnedTextWarning(clean), isNull);
    expect(burnedTextWarning(unchecked), isNull);
  });

  test('导出前的汇总：点名是哪几条，不是「有素材有问题」', () {
    expect(burnedTextSummary(const []), isNull);
    final s = burnedTextSummary([
      (label: 'U1', material: dirty),
      (label: 'U3 的 S2', material: clean),
    ])!;
    expect(s, contains('U1'));
    expect(s, isNot(contains('U3')));
    expect(s, contains('冰冰凉凉的好舒服呀'));
  });
}
