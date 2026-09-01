import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **自动铺一版：参考里这一行有几个分镜，就铺几个。**
///
/// 产品负责人定的规矩：「第一行只有一个分镜，你就找一个；第三行里面有 9 个
/// 分镜，你就要找 9 个，然后自动去切对应的时间——这是机械化的程序。」
///
/// 这里曾经只看 `refSegs.first`：一行不管有几个原子，都只找一条素材塞给整行，
/// 参考片的节奏全丢了。
void main() {
  String bodyOf(String path, String signature) {
    final src = File(path).readAsStringSync();
    final from = src.indexOf(signature);
    expect(from, isNot(-1), reason: '找不到 $signature');
    // 从 `async {` 开始数，别被签名里命名参数的那对大括号骗了
    var depth = 0;
    var i = src.indexOf('async {', from) + 'async '.length;
    final start = i;
    while (i < src.length) {
      if (src[i] == '{') depth++;
      if (src[i] == '}') {
        depth--;
        if (depth == 0) break;
      }
      i++;
    }
    return src.substring(start, i + 1);
  }

  test('逐个参考分镜去铺，不拿第一镜代表整行', () {
    final body = bodyOf('lib/features/director/director_page.dart',
        'Future<List<int>> _autoPickShotByReference(');
    expect(body, contains('refSegs.length'),
        reason: '要遍历这一行的每一个原子');
    expect(body.contains('refSegs.first'), isFalse,
        reason: '拿第一镜代表整行 = 9 个分镜的行只铺一条素材，节奏全没了');
  });

  test('时长按参考的比例切，不是均分', () {
    final body = bodyOf('lib/features/director/director_page.dart',
        'Future<List<int>> _autoPickShotByReference(');
    expect(body, contains('distributeByReference'),
        reason: '均分会把参考里 0.5 秒的快切和 3 秒的定格拉成一样长——'
            '而节奏正是复刻要复刻的东西');
  });

  test('某一镜没搜到要点名，不许静默少铺一个', () {
    final body = bodyOf('lib/features/director/director_page.dart',
        'Future<List<int>> _autoPickShotByReference(');
    expect(body, contains('missed.add'),
        reason: '少铺一个镜头人看不出来，导出时才发现那一段是空的');
  });

  test('花钱按分镜算：一句 9 个分镜就是 9 次识图，不能按句报', () {
    final src =
        File('lib/features/director/director_page.dart').readAsStringSync();
    expect(src, contains('draftSegCount'),
        reason: '按句报会少报一大截——人以为花五块，实际花三十');
  });
}
