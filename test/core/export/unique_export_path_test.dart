import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/unique_export_path.dart';
import 'package:path/path.dart' as p;

Directory _tmp() {
  final d = Directory.systemTemp.createTempSync('ishkafel_unique_');
  addTearDown(() {
    if (d.existsSync()) d.deleteSync(recursive: true);
  });
  return d;
}

void main() {
  test('目录里没这个名字就原样用', () {
    final dir = _tmp();
    expect(uniqueExportPath(dir.path, '变体1.mp4'),
        p.join(dir.path, '变体1.mp4'));
  });

  test('撞上已有文件就往后排，绝不覆盖', () {
    final dir = _tmp();
    File(p.join(dir.path, '变体1.mp4')).writeAsStringSync('上一批');

    final next = uniqueExportPath(dir.path, '变体1.mp4');

    expect(p.basename(next), '变体1(2).mp4');
    // 上一批还在，内容没被动过
    expect(File(p.join(dir.path, '变体1.mp4')).readAsStringSync(), '上一批');
  });

  test('连撞多次一路往后排', () {
    final dir = _tmp();
    for (final name in ['变体1.mp4', '变体1(2).mp4', '变体1(3).mp4']) {
      File(p.join(dir.path, name)).writeAsStringSync('x');
    }
    expect(p.basename(uniqueExportPath(dir.path, '变体1.mp4')), '变体1(4).mp4');
  });

  test('序号加在扩展名之前——不能变成 变体1.mp4(2)，那样双击打不开', () {
    final dir = _tmp();
    File(p.join(dir.path, 'A-居家写实线.mov')).writeAsStringSync('x');
    expect(p.basename(uniqueExportPath(dir.path, 'A-居家写实线.mov')),
        'A-居家写实线(2).mov');
  });

  test('名字里本来就有点，只认最后一段是扩展名', () {
    final dir = _tmp();
    File(p.join(dir.path, 'A.线.mp4')).writeAsStringSync('x');
    expect(p.basename(uniqueExportPath(dir.path, 'A.线.mp4')), 'A.线(2).mp4');
  });

  test('目录还不存在时也能算——导出前才创建目录', () {
    final dir = _tmp();
    final sub = p.join(dir.path, '还没建');
    expect(uniqueExportPath(sub, '变体1.mp4'), p.join(sub, '变体1.mp4'));
  });

  test('同名的目录也算占位——写不进去的名字不能返回', () {
    final dir = _tmp();
    Directory(p.join(dir.path, '变体1.mp4')).createSync();
    expect(p.basename(uniqueExportPath(dir.path, '变体1.mp4')), '变体1(2).mp4');
  });
}
