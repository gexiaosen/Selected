import Foundation

/// 应用版本信息（关于页展示）
public enum AppInfo {
    /// 当前版本号：唯一源头为 Info.plist 的 CFBundleShortVersionString
    /// （发版只改 Info.plist 一处，与 README 版本记录同步）
    public static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    /// 仓库地址：关于页「反馈问题」入口用
    public static let repoURL = "https://github.com/gexiaosen/Selected"
    /// 反馈（新建 Issue）直达地址
    public static let issuesURL = "\(repoURL)/issues/new"
    /// 构建日期（主可执行文件修改时间；build_app.sh 的 cp 使其等于打包时刻）
    public static let buildDate: String = {
        // 北京时间：与全项目其余日期口径一致（裸 DateFormatter 会跟随系统时区）
        let f = ChinaTime.dayFormatter
        if let exe = Bundle.main.executableURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: exe.path),
           let d = attrs[.modificationDate] as? Date {
            return f.string(from: d)
        }
        return f.string(from: Date())
    }()
}
