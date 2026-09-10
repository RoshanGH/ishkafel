import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/shared/thumb_image.dart';

/// **缩略图必须按显示尺寸解码。**
///
/// 素材是 1080×1920 竖屏，一张解成 RGBA 就是 8.3MB。候选面板一屏几十张、
/// 审核页一次上百张——全按原尺寸解码是几百 MB 内存，而真正画到屏幕上的
/// 只有一百来个逻辑像素宽（picked_tray 里那格更只有 13pt）。
void main() {
  late Directory dir;
  late String png;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('thumb-test');
    png = '${dir.path}/a.png';
    // 1×1 透明 PNG
    File(png).writeAsBytesSync([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
      0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0,
      0x1F, 0x15, 0xC4, 0x89, 0, 0, 0, 10, 73, 68, 65, 84, 120, 156, 99, 0,
      1, 0, 0, 5, 0, 1, 13, 0x0A, 0x2D, 0xB4, 0, 0, 0, 0, 73, 69, 78, 68,
      0xAE, 0x42, 0x60, 0x82,
    ]);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<Image> pumpAndFind(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
    return tester.widget<Image>(find.byType(Image));
  }

  testWidgets('给了宽度就按那个宽度解码（乘设备像素比）', (tester) async {
    final image = await pumpAndFind(
        tester, Center(child: ThumbImage(path: png, width: 100)));

    final provider = image.image as ResizeImage;
    expect(provider.width, isNotNull);
    expect(provider.width, greaterThan(100),
        reason: '要乘 devicePixelRatio，不然 Retina 上会糊');
    expect(provider.width, lessThan(1080),
        reason: '100pt 宽的格子解成 1080 是白付一次全尺寸解码');
  });

  testWidgets('没给宽度就量控件实际拿到多宽', (tester) async {
    final image = await pumpAndFind(
      tester,
      Center(child: SizedBox(width: 40, height: 71, child: ThumbImage(path: png))),
    );

    final provider = image.image as ResizeImage;
    expect(provider.width, lessThan(200),
        reason: '40pt 的小格子不该按 1080 解');
  });

  testWidgets('再小的格子也有解码下限，不至于糊成马赛克', (tester) async {
    final image = await pumpAndFind(
      tester,
      Center(child: SizedBox(width: 8, height: 14, child: ThumbImage(path: png))),
    );

    final provider = image.image as ResizeImage;
    expect(provider.width, greaterThanOrEqualTo(64));
  });

  testWidgets('文件读不出来时画兜底，不炸整页', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ThumbImage(
          path: '${dir.path}/不存在.png',
          width: 50,
          errorBuilder: (_) => const Text('读不出'),
        ),
      ),
    ));
    // 解码失败是异步回来的：真实时钟走一下，再走几帧
    await tester.runAsync(() => Future<void>.delayed(
        const Duration(milliseconds: 120)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('读不出'), findsOneWidget);
  });
}
