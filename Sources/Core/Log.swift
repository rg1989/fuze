import os

enum Log {
    static let app = Logger(subsystem: "com.rgv250cc.Fuse", category: "app")
    static let scroll = Logger(subsystem: "com.rgv250cc.Fuse", category: "scroll")
    static let tiling = Logger(subsystem: "com.rgv250cc.Fuse", category: "tiling")
    static let clipboard = Logger(subsystem: "com.rgv250cc.Fuse", category: "clipboard")
    static let capture = Logger(subsystem: "com.rgv250cc.Fuse", category: "capture")
    static let voice = Logger(subsystem: "com.rgv250cc.Fuse", category: "voice")
    static let downloader = Logger(subsystem: "com.rgv250cc.Fuse", category: "downloader")
    static let notes = Logger(subsystem: "com.rgv250cc.Fuse", category: "notes")
    static let notifications = Logger(subsystem: "com.rgv250cc.Fuse", category: "notifications")
}
