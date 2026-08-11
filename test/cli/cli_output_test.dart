import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/cli_output.dart';

/// CLI 的输出约定。
///
/// 这份输出既要给程序读，也要能被人一眼看懂——排查问题时人是要直接跑这条
/// 命令的（这正是选 CLI 而不是 MCP 的理由之一）。
void main() {
  test('JSON 一行输出，调用方按行读就行', () {
    final buffer = StringBuffer();
    emitJson({'ok': true, 'id': 'abc'}, out: buffer);
    expect(buffer.toString().trim().split('\n'), hasLength(1));
    expect(jsonDecode(buffer.toString()), {'ok': true, 'id': 'abc'});
  });

  test('中文不转义——报错要给人看', () {
    final buffer = StringBuffer();
    emitJson({'reason': '任务不存在'}, out: buffer);
    expect(buffer.toString(), contains('任务不存在'));
  });

  test('嵌套结构照常', () {
    final buffer = StringBuffer();
    emitJson({
      'units': [
        {'index': 0, 'tags': ['促单']}
      ]
    }, out: buffer);
    final decoded = jsonDecode(buffer.toString()) as Map;
    expect(((decoded['units'] as List).single as Map)['tags'], ['促单']);
  });

  test('退出码彼此不同——调用方要靠它分辨发生了什么', () {
    expect({exitBadUsage, exitNotFound, exitLocked}, hasLength(3));
    expect([exitBadUsage, exitNotFound, exitLocked], everyElement(isNot(0)));
  });
}
