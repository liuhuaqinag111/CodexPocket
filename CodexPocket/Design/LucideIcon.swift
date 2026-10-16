import SwiftUI
import UIKit

/// Official Lucide 1.56.0 vector assets. See licenses/lucide/manifest.json.
struct LucideIcon: View {
    let name: String
    let size: CGFloat

    init(_ name: String, size: CGFloat = 20) {
        self.name = name
        self.size = size
    }

    var body: some View {
        Image(Self.assetName(name))
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    static func uiImage(_ name: String) -> UIImage? {
        UIImage(named: assetName(name))?.withRenderingMode(.alwaysTemplate)
    }

    static func assetName(_ name: String) -> String {
        let resolved = aliases[name] ?? name
        assert(available.contains(resolved), "Missing Lucide asset: \(name)")
        return "Lucide-" + resolved
    }

    // BEGIN_MANIFEST
    private static let aliases: [String: String] = [
        "archivebox": "archive",
        "arrow.clockwise": "rotate-cw",
        "arrow.down": "arrow-down",
        "arrow.down.circle.fill": "circle-arrow-down",
        "arrow.left": "arrow-left",
        "arrow.right": "arrow-right",
        "arrow.triangle.2.circlepath": "refresh-cw",
        "arrow.triangle.branch": "git-branch",
        "arrow.turn.down.right": "corner-down-right",
        "arrow.up": "arrow-up",
        "arrow.uturn.backward": "undo-2",
        "bolt.fill": "zap",
        "bubble.left.and.bubble.right": "messages-square",
        "chart.bar": "chart-no-axes-column",
        "checklist": "list-checks",
        "checkmark": "check",
        "checkmark.circle.fill": "circle-check",
        "chevron.down": "chevron-down",
        "chevron.left": "chevron-left",
        "chevron.left.forwardslash.chevron.right": "code-xml",
        "chevron.right": "chevron-right",
        "chevron.up": "chevron-up",
        "circle.dashed": "circle-dashed",
        "circle.fill": "circle-dot",
        "circle.inset.filled": "circle-dot",
        "clock.arrow.circlepath": "history",
        "curlybraces": "braces",
        "doc": "file",
        "doc.badge.plus": "file-plus",
        "doc.on.clipboard": "clipboard-paste",
        "doc.on.doc": "copy",
        "doc.text": "file-text",
        "doc.text.magnifyingglass": "file-search",
        "ellipsis": "ellipsis",
        "exclamationmark.circle": "circle-alert",
        "exclamationmark.triangle": "triangle-alert",
        "folder.badge.questionmark": "folder-search",
        "folder.fill": "folder",
        "gearshape": "settings",
        "house": "house",
        "line.3.horizontal": "menu",
        "line.3.horizontal.decrease.circle": "list-filter",
        "line.3.horizontal.decrease.circle.fill": "list-filter",
        "magnifyingglass": "search",
        "person.2": "users",
        "person.crop.circle": "circle-user-round",
        "photo": "image",
        "puzzlepiece.extension": "puzzle",
        "quote.bubble": "message-square-quote",
        "slider.horizontal.3": "sliders-horizontal",
        "speaker.wave.2": "volume-2",
        "square.and.arrow.down": "download",
        "square.and.pencil": "square-pen",
        "square.stack.3d.up": "layers",
        "stop.circle": "circle-stop",
        "stop.fill": "square",
        "tray.and.arrow.up": "archive-restore",
        "waveform": "audio-lines",
        "wifi.exclamationmark": "wifi-off",
        "wifi.slash": "wifi-off",
        "wrench.and.screwdriver": "wrench",
        "xmark": "x",
        "xmark.circle.fill": "circle-x",
    ]
    private static let available: Set<String> = [
        "activity",
        "archive",
        "archive-restore",
        "arrow-down",
        "arrow-down-to-line",
        "arrow-left",
        "arrow-right",
        "arrow-up",
        "arrow-up-right",
        "audio-lines",
        "bell",
        "bolt",
        "braces",
        "brain",
        "camera",
        "chart-no-axes-column",
        "chart-no-axes-combined",
        "check",
        "chevron-down",
        "chevron-left",
        "chevron-right",
        "chevron-up",
        "circle",
        "circle-alert",
        "circle-arrow-down",
        "circle-check",
        "circle-dashed",
        "circle-dot",
        "circle-help",
        "circle-pause",
        "circle-stop",
        "circle-user-round",
        "circle-x",
        "clipboard",
        "clipboard-paste",
        "clock",
        "clock-arrow-up",
        "code",
        "code-xml",
        "copy",
        "corner-down-right",
        "database",
        "download",
        "ellipsis",
        "external-link",
        "eye",
        "file",
        "file-code",
        "file-code-2",
        "file-image",
        "file-json",
        "file-json-2",
        "file-plus",
        "file-search",
        "file-text",
        "folder",
        "folder-input",
        "folder-open",
        "folder-plus",
        "folder-search",
        "git-branch",
        "git-fork",
        "globe",
        "hard-drive",
        "hash",
        "history",
        "house",
        "image",
        "inbox",
        "info",
        "keyboard",
        "layers",
        "layers-2",
        "link",
        "list-checks",
        "list-filter",
        "loader-circle",
        "lock",
        "maximize-2",
        "menu",
        "message-circle",
        "message-square",
        "message-square-quote",
        "messages-square",
        "mic",
        "monitor",
        "moon",
        "network",
        "panel-left",
        "panels-top-left",
        "pause",
        "pencil",
        "phone",
        "phone-off",
        "play",
        "plug-zap",
        "plus",
        "puzzle",
        "refresh-cw",
        "rotate-cw",
        "search",
        "send",
        "server",
        "settings",
        "settings-2",
        "shield-check",
        "shrink",
        "sliders-horizontal",
        "smartphone",
        "sparkles",
        "square",
        "square-pen",
        "sun",
        "terminal",
        "trash",
        "trash-2",
        "triangle-alert",
        "undo-2",
        "unplug",
        "upload",
        "user",
        "user-round",
        "users",
        "volume-2",
        "wifi",
        "wifi-off",
        "wrench",
        "x",
        "zap",
    ]
    // END_MANIFEST
}

struct LucideLabel: View {
    let title: String
    let icon: String

    init(_ title: String, _ icon: String) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        Label { Text(title) } icon: { LucideIcon(icon) }
    }
}
