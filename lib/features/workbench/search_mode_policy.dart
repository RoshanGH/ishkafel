import '../../core/miaoa/miaoa_content_service.dart';

/// 这一刻该用哪种检索方式，外加「是不是程序自动落下来的」
typedef SearchModeDecision = ({CandidateSearchMode mode, bool autoFellBack});

/// 标签用不了时落到画面描述；**能用了要切回来**。
///
/// 原来的实现只往下切不往回切：碰到一个没打上标签的镜头之后，后面每一个镜头
/// 都停在画面描述模式，哪怕它们标签好好的——用户还以为自己在按标签搜，
/// 结果对不上也找不出原因。
///
/// 关键在于区分「程序自动落的」和「用户自己选的」：前者要在标签恢复可用时
/// 收回来，后者绝不能被抢走。
SearchModeDecision nextSearchMode({
  required CandidateSearchMode current,
  required bool tagAvailable,
  required bool tagPending,
  required bool descriptionSupported,
  required bool userPinned,
  bool autoFellBack = false,
}) {
  // 整体替换没有画面描述这条路：画面描述是对单个镜头生成的，一整句台词
  // 对应一串镜头，没有一句能代表它们的描述
  if (!descriptionSupported && current == CandidateSearchMode.description) {
    return (mode: CandidateSearchMode.tag, autoFellBack: false);
  }

  // 「还在读标签表」不是「用不了」：这一刻切走，拉完一切正常时用户就白白
  // 丢了主路径
  if (tagPending) return (mode: current, autoFellBack: autoFellBack);

  if (current == CandidateSearchMode.tag) {
    if (tagAvailable || !descriptionSupported) {
      return (mode: current, autoFellBack: false);
    }
    return (mode: CandidateSearchMode.description, autoFellBack: true);
  }

  // 自动落下来的，标签一恢复就收回来；用户手动选的不动
  if (autoFellBack && !userPinned && tagAvailable) {
    return (mode: CandidateSearchMode.tag, autoFellBack: false);
  }
  return (mode: current, autoFellBack: autoFellBack);
}
