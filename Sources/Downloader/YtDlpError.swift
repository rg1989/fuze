import Foundation

/// Classifies yt-dlp's raw stderr into a small set of human-meaningful
/// failures so the Downloads UI shows actionable text instead of dumping
/// 20 lines of Python traceback. Pure and order-sensitive (specific
/// signatures are checked before generic ones); fully unit-tested.
enum YtDlpFailure: Equatable {
    /// Site changed shape / extractor can't parse it (incl. bot-challenge
    /// pages like IMDb's AWS WAF that yt-dlp reports as "next.js" failures).
    case extractorBroken
    /// Private, members-only, or age-restricted — needs an account.
    case needsSignIn
    /// Region-locked.
    case geoBlocked
    /// Site is throttling requests (HTTP 429).
    case rateLimited
    /// Removed, deleted, or otherwise gone.
    case unavailable
    /// Not a site yt-dlp has an extractor for.
    case unsupportedSite
    /// Reachable, but no downloadable media at the URL.
    case noVideoFound
    /// Couldn't reach the network / DNS / server 5xx.
    case network
    /// Merge/convert needs ffmpeg and it isn't installed.
    case ffmpegMissing
    /// Anything unrecognized — carries the cleanest single line we could find.
    case unknown(String)

    var message: String {
        switch self {
        case .extractorBroken:
            return "This site recently changed and the downloader can't read it yet. "
                + "This is usually fixed within a few days — try again later, or force an "
                + "update in Settings → Downloads."
        case .needsSignIn:
            return "This video needs an account — it's private, members-only, or "
                + "age-restricted. Fuse can't download videos that require signing in."
        case .geoBlocked:
            return "This video is blocked in your region."
        case .rateLimited:
            return "The site is temporarily limiting downloads. Wait a few minutes and try again."
        case .unavailable:
            return "This video is unavailable — it may have been removed, deleted, or set to private."
        case .unsupportedSite:
            return "This link isn't from a site Fuse can download from."
        case .noVideoFound:
            return "No downloadable video was found at this link."
        case .network:
            return "Couldn't reach the site. Check your internet connection and try again."
        case .ffmpegMissing:
            return "This format needs ffmpeg, which isn't installed. "
                + "Install it with Homebrew: brew install ffmpeg"
        case .unknown(let detail):
            return detail.isEmpty
                ? "Download failed. See Console logs (subsystem com.rgv250cc.Fuse) for details."
                : "Download failed: \(detail)"
        }
    }

    /// Maps raw stderr to a failure category. Substring signatures are matched
    /// case-insensitively in priority order: the FIRST match wins, so the most
    /// specific causes are listed before the generic catch-alls.
    static func classify(stderr: String) -> YtDlpFailure {
        let s = stderr.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { s.contains($0) } }

        // ffmpeg first: its message also contains "requested merging" noise.
        if has("ffmpeg is not installed", "ffprobe and ffmpeg not found",
               "ffmpeg not found") {
            return .ffmpegMissing
        }
        if has("sign in to confirm", "log in to", "login required", "requires authentication",
               "private video", "members-only", "members only", "join this channel",
               "available to this channel's members", "only available for registered",
               "age-restricted", "inappropriate for some users", "confirm your age") {
            return .needsSignIn
        }
        if has("not available in your country", "not available from your location",
               "in your location", "in your country", "geo restriction", "geo-restricted",
               "blocked it in your country", "the uploader has not made this video available") {
            return .geoBlocked
        }
        if has("http error 429", "too many requests", "rate-limit", "rate limit") {
            return .rateLimited
        }
        if has("video unavailable", "has been removed", "no longer available",
               "has been deleted", "account associated with this video has been terminated",
               "removed for violating", "content isn't available", "video isn't available",
               "this video is not available", "this video has been removed") {
            return .unavailable
        }
        if has("unsupported url", "no suitable extractor", "is not a valid url") {
            return .unsupportedSite
        }
        // Extractor breakage / bot-challenge pages (the IMDb "next.js" case).
        if has("unable to extract", "next.js", "please report this issue",
               "unable to download json metadata", "failed to parse json",
               "unable to extract initial data", "unable to extract player") {
            return .extractorBroken
        }
        if has("no video formats found", "requested format is not available",
               "no media found", "there's no video", "no video could be found") {
            return .noVideoFound
        }
        if has("unable to download webpage", "urlopen error", "getaddrinfo",
               "temporary failure in name resolution", "connection refused",
               "connection reset", "network is unreachable", "timed out",
               "failed to resolve", "http error 5") {
            return .network
        }
        return .unknown(cleanedErrorLine(stderr))
    }

    /// Convenience: the user-facing message for raw stderr in one step.
    static func friendlyMessage(stderr: String) -> String {
        classify(stderr: stderr).message
    }

    /// Best-effort extraction of the single most relevant line from a noisy
    /// stderr tail: prefer the last `ERROR:` line, strip the `ERROR:` prefix,
    /// any `[extractor] id:` prefix, and yt-dlp's "; please report…" tail.
    static func cleanedErrorLine(_ stderr: String) -> String {
        let lines = stderr
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard var line = lines.last(where: { $0.lowercased().hasPrefix("error:") })
            ?? lines.last else { return "" }

        if let r = line.range(of: "error:", options: .caseInsensitive) {
            line = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        // Strip a leading "[extractor] 12345:" prefix if present.
        if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
            let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            // Drop a following "<id>:" token (e.g. "662489881:").
            if let colon = rest.firstIndex(of: ":") {
                line = String(rest[rest.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            } else {
                line = rest
            }
        }
        if let r = line.range(of: "; please report", options: .caseInsensitive) {
            line = String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return line
    }
}
