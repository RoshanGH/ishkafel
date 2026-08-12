import 'dart:io';

import 'package:path/path.dart' as p;

/// 一个 Agent 的用户级技能目录。
///
/// **用户级，不是工作目录级**：`AGENTS.md` 那类文件跟着「文件夹」走，说的是
/// 「你现在干活的这个目录是怎么回事」；而「这个工具怎么用」跟目录无关——
/// 使用者在哪个文件夹干活都该生效。所以装到 `~/.claude/skills/` 这种地方。
class SkillTarget {
  /// 界面上怎么称呼它
  final String agent;

  /// 技能目录，例如 `~/.claude/skills`
  final Directory dir;

  const SkillTarget({required this.agent, required this.dir});

  File get file => File(p.join(dir.path, SkillInstaller.skillName, 'SKILL.md'));
}

class SkillStatus {
  /// 装了且是当前版本
  final List<SkillTarget> installed;

  /// 装了但是旧版本
  final List<SkillTarget> outdated;

  /// 没装
  final List<SkillTarget> missing;

  const SkillStatus(
      {required this.installed, required this.outdated, required this.missing});

  bool get allCurrent => missing.isEmpty && outdated.isEmpty;
  bool get anyPresent => installed.isNotEmpty || outdated.isNotEmpty;
}

class SkillInstallResult {
  final bool ok;
  final String message;

  const SkillInstallResult({required this.ok, required this.message});
}

/// 把给 Agent 的操作手册装进各家 Agent 的用户级技能目录。
///
/// 这一步补的是最后一个缺口：使用者装了 app、装了命令行工具，Agent 有了
/// 「能调什么」，还缺「怎么用才做得出能用的片子」。
class SkillInstaller {
  static const skillName = 'ishkafel';

  final List<SkillTarget> targets;

  /// 手册正文（编在二进制里，见 tool/gen_agent_skill.dart）
  final String markdown;

  /// 当前 app 版本。写进文件里，将来能判断手上那份是不是旧的
  final String version;

  const SkillInstaller(
      {required this.targets, required this.markdown, required this.version});

  /// 按当前用户的家目录组装默认目标
  factory SkillInstaller.forCurrentUser({
    required String markdown,
    required String version,
    String? home,
  }) {
    final base = home ??
        Platform.environment['HOME'] ??
        Directory.current.path;
    return SkillInstaller(
      markdown: markdown,
      version: version,
      targets: [
        SkillTarget(
            agent: 'Claude Code',
            dir: Directory(p.join(base, '.claude', 'skills'))),
        SkillTarget(
            agent: 'Codex', dir: Directory(p.join(base, '.codex', 'skills'))),
      ],
    );
  }

  SkillStatus inspect() {
    final installed = <SkillTarget>[];
    final outdated = <SkillTarget>[];
    final missing = <SkillTarget>[];
    for (final target in targets) {
      if (!target.file.existsSync()) {
        missing.add(target);
        continue;
      }
      String body;
      try {
        body = target.file.readAsStringSync();
      } catch (_) {
        missing.add(target);
        continue;
      }
      // 说明书跟着工具版本走：旧副本会让 Agent 照着旧文档调新命令，
      // 报错还不知道为什么
      (body.contains(_versionLine) ? installed : outdated).add(target);
    }
    return SkillStatus(
        installed: installed, outdated: outdated, missing: missing);
  }

  Future<SkillInstallResult> install() async {
    final done = <String>[];
    final failed = <String>[];
    for (final target in targets) {
      try {
        target.file.parent.createSync(recursive: true);
        target.file.writeAsStringSync(_skillFile());
        done.add(target.agent);
      } catch (e) {
        failed.add('${target.agent}（$e）');
      }
    }
    if (done.isEmpty) {
      return SkillInstallResult(ok: false, message: '一个都没装上：${failed.join('、')}');
    }
    final note = failed.isEmpty ? '' : '；没装上：${failed.join('、')}';
    return SkillInstallResult(
      ok: failed.isEmpty,
      message: '已装给 ${done.join('、')}$note。'
          '之后在任意文件夹跟 Agent 说「用 ishkafel 翻新这条片子」即可',
    );
  }

  /// 删掉装过的那些，返回删了几份
  Future<int> uninstall() async {
    var removed = 0;
    for (final target in targets) {
      if (!target.file.existsSync()) continue;
      try {
        target.file.deleteSync();
        final dir = target.file.parent;
        if (dir.listSync().isEmpty) dir.deleteSync();
        removed++;
      } catch (_) {}
    }
    return removed;
  }

  String get _versionLine => '<!-- ishkafel-skill $version -->';

  /// frontmatter 里的 `description` 决定 Agent **什么时候会想起用它**。
  /// 只写「ishkafel 的使用说明」的话，用户说「把这条片子换个画面」时它不会
  /// 联想到这里——所以要把触发场景写进去。
  String _skillFile() => '''---
name: $skillName
description: >-
  用 ishkafel 做成片翻新：拿一条已有的成片，保持台词与结构不变、把画面换成
  新素材，产出若干条结构相同但画面全新的视频。当用户提到成片翻新、换画面、
  换分镜、替换素材、批量出片、或直接点名 ishkafel 时使用。也覆盖导入视频、
  语义切分与打标、挑替换素材、组方案、导出这几步的具体做法。
---

$_versionLine

$markdown''';
}
