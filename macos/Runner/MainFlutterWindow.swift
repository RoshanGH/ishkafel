import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// 默认窗口尺寸。
  ///
  /// 审片台是三栏（单元列表 320 + 播放器 + 检查器 300）加双层时间线，
  /// xib 里默认的 800×600 下：横向播放器只剩两百多像素、竖屏画面几乎看不清；
  /// 纵向时间线区只有约 145px，而四条轨（含标题条）需要 248px，音频波形轨
  /// 整条落在可视区外。这里给一个真正能工作的初始尺寸。
  private static let defaultSize = NSSize(width: 1440, height: 900)

  /// 最小窗口尺寸。
  ///
  /// 高度由时间线反推：四条轨（含标题条）248px + 工具条约 50px = 298px，
  /// 而时间线区占 body 的 2/5，body = 高度 − 顶栏 52 − 底栏 60 − 分隔线 1，
  /// 于是最低 298×5/2 + 113 ≈ 858。取 880 留一点余量。
  /// 见 test/features/workbench/timeline/timeline_tracks_layout_test.dart。
  private static let minSize = NSSize(width: 1100, height: 880)

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    self.contentMinSize = MainFlutterWindow.minSize
    let target = NSRect(
      origin: self.frame.origin,
      size: MainFlutterWindow.defaultSize
    )
    self.setFrame(target, display: true)
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
