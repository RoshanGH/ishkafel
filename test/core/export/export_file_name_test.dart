import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/export_file_name.dart';

/// 手册白纸黑字写着「方案名会成为导出文件名，重名会互相覆盖」，
/// 而实现一直在导 `变体0.mp4` / `变体1.mp4`——验收 Agent 照着手册特意给三条
/// 方案起了能区分的名字（A-居家写实线 / B-跨项目混编线 / C-轻快生活线），
/// 一个都没用上。
///
/// 对拿到片子的人也是实打实的麻烦：三条方案本来就是设计成有区别的，
/// 文件名把这个区别抹平，要回头翻 JSON 才知道哪条是哪条。
void main() {
  test('有名字就用名字', () {
    expect(exportFileName(name: 'A-居家写实线', index: 0, extension: 'mp4'),
        'A-居家写实线.mp4');
  });

  test('没名字退回变体编号——界面上枚举出来的组合本来就没名字', () {
    expect(exportFileName(name: null, index: 2, extension: 'mp4'), '变体2.mp4');
    expect(exportFileName(name: '   ', index: 2, extension: 'mp4'), '变体2.mp4');
  });

  test('路径分隔符和冒号要清掉——不清会写到别处去，或者根本建不出文件', () {
    expect(exportFileName(name: 'A/B:C', index: 0, extension: 'mp4'),
        'A-B-C.mp4');
    // 首尾的点也去掉：以点开头在 Finder 里是隐藏文件，
    // 人会以为片子没导出来
    expect(exportFileName(name: '../../etc/passwd', index: 0, extension: 'mp4'),
        'etc-passwd.mp4');
  });

  test('清洗完什么都不剩，退回变体编号', () {
    expect(exportFileName(name: '///', index: 1, extension: 'mp4'), '变体1.mp4');
  });

  test('太长的名字要截断——文件系统有上限，超了整条导出会失败', () {
    final long = '很长的方案名' * 40;
    final out = exportFileName(name: long, index: 0, extension: 'mp4');

    expect(out.length, lessThanOrEqualTo(84));
    expect(out, endsWith('.mp4'));
  });

  test('换行和制表符压成空格，不留在文件名里', () {
    expect(exportFileName(name: 'A\n线\t二', index: 0, extension: 'mp4'),
        'A 线 二.mp4');
  });
}
