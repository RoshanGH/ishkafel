import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 命令行工具是**纯 Dart** 编译（`dart build cli`），整条 import 链里
/// 沾一个 flutter 包就完蛋——而且不是干脆地报「找不到」，是编译器自己崩：
///
///     type 'InvalidType' is not a subtype of type 'FunctionType' in type cast
///     #0  _FfiUseSiteTransformer._verifyAndReplaceNativeCallable
///
/// 报错里没有文件名、没有包名，全是编译器内部堆栈。真机上栽过两次，
/// 第二次是 `script_command` 引了编导台的 providers（那文件引 riverpod），
/// 白烧了三个版本号才找到。所以这条线得有人守着。
void main() {
  test('命令行工具的 import 链里不许出现 flutter', () {
    final root = Directory.current.path;
    final visited = <String>{};
    final offenders = <String, List<String>>{};

    void walk(String file, List<String> trail) {
      if (!visited.add(file) || !File(file).existsSync()) return;
      final source = File(file).readAsStringSync();
      for (final m
          in RegExp(r"""^(?:import|export)\s+'([^']+)'""", multiLine: true)
              .allMatches(source)) {
        final uri = m.group(1)!;
        if (uri.startsWith('package:flutter')) {
          offenders[p.relative(file, from: root)] = [...trail, uri];
          continue;
        }
        final next = uri.startsWith('package:ishkafel/')
            ? p.join(root, 'lib', uri.substring('package:ishkafel/'.length))
            : (uri.startsWith('package:') || uri.startsWith('dart:'))
                ? null
                : p.normalize(p.join(p.dirname(file), uri));
        if (next != null) {
          walk(next, [...trail, p.relative(file, from: root)]);
        }
      }
    }

    walk(p.join(root, 'bin', 'ishkafel.dart'), const []);

    expect(offenders, isEmpty,
        reason: '这些文件把 flutter 拖进了命令行工具，编译会以编译器崩溃收场：\n'
            '${offenders.entries.map((e) => '  ${e.key} -> ${e.value.last}\n'
                '    经由 ${e.value.take(e.value.length - 1).join(' -> ')}').join('\n')}');
  });
}
