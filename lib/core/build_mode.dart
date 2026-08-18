/// 当前是不是调试构建（`flutter run` / `flutter build --debug` 的产物）。
///
/// 调试构建**天生**不带云端 AI 凭据、不带内置命令行工具——那些是打包脚本
/// 塞进正式包的。用户误开调试版时，界面必须自报家门（「这是开发调试版」），
/// 而不是让「凭据未配置」这类提示把他引去找同事重新打包——真机上发生过
/// 两次，用户以为软件坏了。
const bool isDebugBuild = !bool.fromEnvironment('dart.vm.product');
