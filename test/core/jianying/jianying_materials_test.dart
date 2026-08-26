import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/jianying/jianying_materials.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('jy_stage_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String src(String name, String content) {
    final f = File(p.join(tmp.path, name))..writeAsStringSync(content);
    return f.path;
  }

  test('落地后草稿目录里读得到同样的内容', () {
    final stager = MaterialStager(p.join(tmp.path, 'draft', 'materials'));
    final dest = stager.stage(src('a.mp4', 'hello'));
    expect(File(dest).readAsStringSync(), 'hello');
    expect(p.dirname(dest), endsWith('materials'));
  });

  test('用的是硬链接：同一个 inode，不占额外空间', () {
    final stager = MaterialStager(p.join(tmp.path, 'draft', 'materials'));
    final source = src('b.mp4', 'x' * 1024);
    final dest = stager.stage(source);
    final a = File(source).statSync();
    final b = File(dest).statSync();
    expect(b.size, a.size);
    // 硬链接不是符号链接——沙盒按最终路径判权限，符号链接会被剪映拒之门外
    expect(FileSystemEntity.isLinkSync(dest), isFalse,
        reason: '符号链接会让剪映顺着读回我们的缓存目录，照样没权限');
  });

  test('删掉源文件，草稿那份还在（两边独立）', () {
    final stager = MaterialStager(p.join(tmp.path, 'draft', 'materials'));
    final source = src('c.mp4', 'keep me');
    final dest = stager.stage(source);
    File(source).deleteSync();
    expect(File(dest).existsSync(), isTrue);
    expect(File(dest).readAsStringSync(), 'keep me',
        reason: '用户在 ishkafel 里清了缓存，剪映里的草稿必须照常打开');
  });

  test('同一个源只落一次', () {
    final stager = MaterialStager(p.join(tmp.path, 'draft', 'materials'));
    final source = src('d.mp4', 'once');
    expect(stager.stage(source), stager.stage(source));
    expect(stager.count, 1);
  });

  test('不同源同名时让路，不互相覆盖', () {
    final stager = MaterialStager(p.join(tmp.path, 'draft', 'materials'));
    final one = Directory(p.join(tmp.path, 'one'))..createSync();
    final two = Directory(p.join(tmp.path, 'two'))..createSync();
    final a = File(p.join(one.path, 'clip.mp4'))..writeAsStringSync('AAA');
    final b = File(p.join(two.path, 'clip.mp4'))..writeAsStringSync('BBB');
    final da = stager.stage(a.path);
    final db = stager.stage(b.path);
    expect(da, isNot(db));
    expect(File(da).readAsStringSync(), 'AAA');
    expect(File(db).readAsStringSync(), 'BBB');
  });

  test('源文件不存在就报错，不静默跳过', () {
    final stager = MaterialStager(p.join(tmp.path, 'draft', 'materials'));
    expect(() => stager.stage(p.join(tmp.path, 'nope.mp4')),
        throwsA(isA<FileSystemException>()));
  });
}
