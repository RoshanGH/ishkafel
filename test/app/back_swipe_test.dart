import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/app/theme/app_theme.dart';

/// 在窗口左边缘附近横向拖一下：不能把当前页拖走。
///
/// macOS 上 Flutter 默认给的是 Cupertino 页面转场，它自带「从左边缘往右拖 =
/// 返回上一页」。而工作台的时间线是贴着窗口左边缘的：在配乐轨最左端（00:00
/// 附近）横向拖选一段镜头，正好落在那条 20pt 宽的返回热区里——用户看到的是
/// 整个工作台被拖走、露出后面的任务列表。
void main() {
  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      // 真机是 macOS：转场与返回手势按主题平台走，不指定的话测试跑的是
      // Android 那套，压根碰不到这个手势
      theme: buildAppTheme().copyWith(platform: TargetPlatform.macOS),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const Scaffold(body: Text('工作台')))),
              child: const Text('进入'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('进入'));
    await tester.pumpAndSettle();
  }

  testWidgets('贴着左边缘往右拖，页面不会被拖走', (tester) async {
    await pump(tester);
    expect(find.text('工作台'), findsOneWidget);

    await tester.dragFrom(const Offset(5, 300), const Offset(400, 0));
    await tester.pumpAndSettle();

    expect(find.text('工作台'), findsOneWidget,
        reason: '时间线贴着窗口左边缘，00:00 附近的拖拽是正经操作，'
            '不能被当成「返回上一页」');
    expect(find.text('进入'), findsNothing);
  });

  testWidgets('返回按钮照常能用——去掉的只是边缘手势', (tester) async {
    await pump(tester);

    Navigator.of(tester.element(find.text('工作台'))).pop();
    await tester.pumpAndSettle();

    expect(find.text('进入'), findsOneWidget);
  });
}
