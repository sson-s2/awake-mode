// AwakeMode: a menu bar item that selects one mode and reports the real state.
//
// Picking a mode writes one word to the mode file and nothing else. The daemon
// owns pmset and caffeinate, so there is exactly one source of truth and the
// icon can be coloured by what is actually true rather than by what was asked.

import AppKit
import Foundation

let stateDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/awake-mode")
let modeURL = stateDirectory.appendingPathComponent("mode")
let statusURL = stateDirectory.appendingPathComponent("status.json")

/// Every visible string. Japanese when macOS is set to Japanese, English otherwise.
enum Strings {
    private static let japanese = (Locale.preferredLanguages.first ?? "en").hasPrefix("ja")
    private static func pick(_ english: String, _ japanese: String) -> String {
        self.japanese ? japanese : english
    }

    static var modeNormal: String { pick("Normal (leave it to macOS)", "通常 (macOS 任せ)") }
    static var modeLid: String { pick("Keep running with the lid closed", "蓋を閉じても動かし続ける") }
    static var modeLock: String { pick("Lock the screen, keep running", "画面をロックして動かし続ける") }
    static var quit: String { pick("Quit", "終了") }
    static var checking: String { pick("Checking…", "確認中…") }

    static var stale: String {
        pick("The watchdog is not running (no update for a minute)",
             "見張りが動いていません (1 分以上 更新なし)")
    }
    static func guarded(_ percent: Int) -> String {
        pick("Battery at \(percent)%: sleep prevention released, mode kept",
             "電池 \(percent)% のためスリープ防止を解除中 (モードは維持)")
    }
    static func notInEffect(_ reason: String) -> String {
        pick("Not in effect: \(reason)", "効いていません: \(reason)")
    }
    static var inEffectLid: String {
        pick("In effect: the lid can be closed", "効いています (蓋を閉じても起きたまま)")
    }
    static var inEffectLock: String {
        pick("In effect: the screen sleeps, the machine does not",
             "効いています (画面は消える・本体は起きたまま)")
    }
    static var offNormal: String { pick("Sleep is left to macOS", "スリープは macOS 任せ") }
    static var lowPowerOn: String { pick(" · low power on", " · 低電力モード入") }

    static func reason(_ code: String, detail: String) -> String {
        switch code {
        case "no_mode_file": return pick("no mode file", "モードファイルが無い")
        case "invalid_mode": return pick("unknown mode '\(detail)'", "不正なモード '\(detail)'")
        case "sudo_denied": return pick("sudo was refused (\(detail))", "sudo が通らない (\(detail))")
        case "pmset_ineffective": return pick("pmset had no effect (\(detail))", "pmset が効いていない (\(detail))")
        case "mismatch": return pick("the wish and the machine disagree", "望みと現実が一致しない")
        case "stopped": return pick("the watchdog stopped", "見張りが停止した")
        case "": return pick("unknown", "原因不明")
        default: return code
        }
    }
}

private struct Status {
    var ok = false
    var guarded = false
    var lowPower = false
    var batteryPercent = 100
    var reason = ""
    var detail = ""
    var timestamp = 0.0

    static func read(from url: URL) -> Status? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var status = Status()
        status.ok = (json["ok"] as? Bool) ?? false
        status.guarded = (json["battery_guard"] as? Bool) ?? false
        status.lowPower = ((json["low_power"] as? Int) ?? 0) == 1
        status.batteryPercent = (json["battery_percent"] as? Int) ?? 100
        status.reason = (json["reason"] as? String) ?? ""
        status.detail = (json["detail"] as? String) ?? ""
        status.timestamp = (json["ts"] as? Double) ?? 0
        return status
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var modeItems: [String: NSMenuItem] = [:]
    private var stateItem: NSMenuItem!
    private var timer: Timer?

    private let modes: [(key: String, title: String)] = [
        ("normal", Strings.modeNormal),
        ("lid", Strings.modeLid),
        ("lock", Strings.modeLock),
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        for mode in modes {
            let item = NSMenuItem(title: mode.title, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.key
            menu.addItem(item)
            modeItems[mode.key] = item
        }
        menu.addItem(.separator())

        stateItem = NSMenuItem(title: Strings.checking, action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: Strings.quit,
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu

        refresh()
        let timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)   // keep ticking while the menu is open
        self.timer = timer
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        do {
            try (mode + "\n").write(to: modeURL, atomically: true, encoding: .utf8)
        } catch {
            stateItem.title = error.localizedDescription
            return
        }
        refresh()   // shows the new wish; the next tick replaces it with the real state
    }

    private func selectedMode() -> String {
        let raw = (try? String(contentsOf: modeURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return modeItems[raw] != nil ? raw : "normal"
    }

    private func refresh() {
        let mode = selectedMode()
        for (key, item) in modeItems { item.state = (key == mode) ? .on : .off }

        let status = Status.read(from: statusURL) ?? Status()
        let stale = Date().timeIntervalSince1970 - status.timestamp > 60

        var text: String
        let color: NSColor
        if stale {
            text = Strings.stale
            color = .systemRed
        } else if status.guarded {
            text = Strings.guarded(status.batteryPercent)
            color = .systemOrange
        } else if !status.ok {
            text = Strings.notInEffect(Strings.reason(status.reason, detail: status.detail))
            color = .systemRed
        } else {
            switch mode {
            case "lid": text = Strings.inEffectLid; color = .systemGreen
            case "lock": text = Strings.inEffectLock; color = .systemGreen
            default: text = Strings.offNormal; color = .secondaryLabelColor
            }
        }
        if status.lowPower && !stale { text += Strings.lowPowerOn }
        stateItem.title = text

        guard let button = statusItem.button else { return }
        let symbol: String
        switch mode {
        case "lid": symbol = "macbook"
        case "lock": symbol = "lock.display"
        default: symbol = "zzz"
        }
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: text) {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.attributedTitle = NSAttributedString(
                string: mode == "normal" ? "zZ" : "AWAKE",
                attributes: [.foregroundColor: color])
        }
        button.contentTintColor = color
        button.toolTip = text
    }
}

@main
enum AwakeModeApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        // NSApplication holds the delegate weakly, so it has to outlive run().
        withExtendedLifetime(delegate) { app.run() }
    }
}
