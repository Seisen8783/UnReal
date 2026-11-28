import Foundation

/// 轨迹来源。
public enum TrackSource: String, CaseIterable, Identifiable, Sendable {
    /// 内置默认轨迹（校园跑走廊），坐标基准固定为 WGS-84。
    case bundled
    /// 本地导入，坐标基准由用户选择。
    case localFile

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bundled: return "默认路径"
        case .localFile: return "本地导入"
        }
    }

    /// 内置默认轨迹的资源名（打包进 App 的 Resources）。
    public static let bundledFileName = "default-track"

    /// 内置默认轨迹的包内 URL。
    public static var bundledURL: URL? {
        Bundle.module.url(forResource: bundledFileName, withExtension: "kmz")
    }
}
