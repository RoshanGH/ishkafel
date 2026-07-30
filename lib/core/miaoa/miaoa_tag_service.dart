import 'dart:convert';
import 'dart:io';
import '../ffmpeg/process_runner.dart';

/// miaoa CLI 调用失败（非零退出码或返回内容非法）
class MiaoaException implements Exception {
  final String message;
  const MiaoaException(this.message);
  @override
  String toString() => 'MiaoaException: $message';
}

/// 标签组（对应 miaoa tag group list 输出）
class TagGroup {
  final int id;
  final String name;
  final String materialType;
  final String tagType;

  const TagGroup({
    required this.id,
    required this.name,
    required this.materialType,
    required this.tagType,
  });

  factory TagGroup.fromJson(Map<String, dynamic> json) => TagGroup(
        id: json['id'] as int,
        name: json['groupName'] as String,
        materialType: json['materialType'] as String,
        tagType: json['tagType'] as String,
      );
}

/// 标签（对应 miaoa tag list 输出）
class TagInfo {
  final int id;
  final String name;

  const TagInfo({required this.id, required this.name});

  factory TagInfo.fromJson(Map<String, dynamic> json) => TagInfo(
        id: json['id'] as int,
        name: json['tagName'] as String,
      );
}

/// miaoa 标签体系拉取（标签组、标签，均为只读子进程调用）
class MiaoaTagService {
  final ProcessRunner run;
  final String binary;

  MiaoaTagService({this.run = systemProcessRunner, this.binary = 'miaoa'});

  Future<List<TagGroup>> listGroups() async {
    final result = await run(
        binary, ['tag', 'group', 'list', '--scope', 'tenant', '--json']);
    final list = _decodeList(result, 'tag group list');
    return list
        .map((e) => TagGroup.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<TagInfo>> listTags(int groupId) async {
    final result = await run(
        binary, ['tag', 'list', '--group', '$groupId', '--json']);
    final list = _decodeList(result, 'tag list');
    return list
        .map((e) => TagInfo.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  List<dynamic> _decodeList(ProcessResult result, String action) {
    if (result.exitCode != 0) {
      throw MiaoaException('miaoa $action 失败（exit=${result.exitCode}）：${result.stderr}');
    }
    try {
      return jsonDecode(result.stdout as String) as List<dynamic>;
    } on FormatException catch (e) {
      throw MiaoaException('miaoa $action 返回非法 JSON：$e');
    }
  }
}
