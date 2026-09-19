import '../core/miaoa/miaoa_tag_service.dart';
import '../core/models/tag_group_ref.dart';

/// `--tag-groups` 传来的 id，解析成能落库的 [TagGroupRef]，缺失的也一并报回去。
///
/// 建任务的几条命令（`blank create` / `script new` / `import`）都要同一套
/// 判断——标签组是打标的受控词表，缺一个就是一条检索路径打不出标签，
/// 不能各写各的（那正是「同一件事两处算」）。
List<int> parseTagGroupIds(String? raw) => [
      for (final piece in (raw ?? '').split(','))
        ?int.tryParse(piece.trim()),
    ];

/// 按 [ids] 在当前企业下查到的标签组，以及查不到的那几个
class TagGroupLookup {
  final List<TagGroupRef> groups;
  final List<int> missing;

  const TagGroupLookup({required this.groups, required this.missing});

  bool get ok => missing.isEmpty;
}

Future<TagGroupLookup> lookupTagGroups(
  List<int> ids, {
  MiaoaTagService? service,
}) async {
  final all = await (service ?? MiaoaTagService()).listGroups();
  final groups = [
    for (final g in all)
      if (ids.contains(g.id)) TagGroupRef(id: g.id, name: g.name),
  ];
  final missing = ids.where((id) => !groups.any((g) => g.id == id)).toList();
  return TagGroupLookup(groups: groups, missing: missing);
}
