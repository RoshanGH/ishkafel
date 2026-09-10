import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **该拦的在进门口拦，不在出门口。**
///
/// 2026-09-10 真机走查：脚本四句只挑了一句的镜头，点「导出成片」照样弹出
/// 规格面板——人选完分辨率、码率、编码、格式，点了「开始导出」，才蹦出
/// 一个「没能导出」。那一遍表单白填了。
void main() {
  test('编导台导出：先问拦不拦得住，再决定要不要开规格面板', () {
    final src =
        File('lib/features/director/director_page.dart').readAsStringSync();
    final at = src.indexOf('Future<void> _exportScript() async {');
    expect(at, isNot(-1), reason: '没找到导出入口，正则该更新了');

    final body = src.substring(at, at + 2000);
    final guard = body.indexOf('blockingReason');
    final dialog = body.indexOf('showScriptExportDialog');

    expect(guard, isNot(-1),
        reason: '导出前不做拦截判断，人会白填一遍规格表单');
    expect(guard, lessThan(dialog), reason: '要先判能不能导，再开规格面板');
  });

  test('拦截原因是纯函数，界面问得到', () {
    final src = File('lib/core/script/script_export.dart').readAsStringSync();

    expect(src, contains('static String? blockingReason('),
        reason: '只在 export() 里抛异常的话，界面没法提前问');
  });
}
