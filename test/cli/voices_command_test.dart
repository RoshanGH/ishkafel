import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/commands/voices_command.dart';

/// `ishkafel voices` —— 列出可选音色。
///
/// 手册里一直写着这条命令（「没定过就先问人要哪个音色，`ishkafel voices`
/// 列可选项，别自己挑一个」），**但它根本不存在**。验收 Agent 撞上了：
/// 它既不能自己挑（手册禁止、而且花的是用户的钱），又没法把选项列给人看，
/// 于是整条配音链路在纯 CLI 下走不通，挑镜头也跟着走不通。
void main() {
  test('列出所有音色，带 id 和名字', () {
    final out = StringBuffer();
    expect(runVoicesCommand(out: out), 0);
    final json = jsonDecode(out.toString()) as Map<String, dynamic>;
    final list = json['voices'] as List;
    expect(list, isNotEmpty);
    final first = list.first as Map<String, dynamic>;
    expect(first['id'], isNotEmpty);
    expect(first['name'], isNotEmpty);
  });

  test('带上场景和语种——人要挑的话得看得出区别', () {
    final out = StringBuffer();
    runVoicesCommand(out: out);
    final first = ((jsonDecode(out.toString())
        as Map<String, dynamic>)['voices'] as List).first as Map;
    expect(first['scene'], isNotNull);
    expect(first['language'], isNotNull);
  });

  test('说清下一步怎么用——别让调用方自己拼命令', () {
    final out = StringBuffer();
    runVoicesCommand(out: out);
    final json = jsonDecode(out.toString()) as Map<String, dynamic>;
    expect('${json['next']}', contains('apply baseline'));
  });
}
