import AppKit
import ApplicationServices

private struct Target {
    let name: String
    let bundleID: String
    let appPath: String
}

private final class Bridge: NSObject, NSApplicationDelegate {
    static let shared = Bridge()
    private let targets = [
        Target(name: "Claude", bundleID: "com.anthropic.claudefordesktop", appPath: "/Applications/Claude.app"),
        Target(name: "Codex", bundleID: "com.openai.codex", appPath: "/Applications/ChatGPT.app"),
        Target(name: "WorkBuddy", bundleID: "com.tencent.workbuddy.mac", appPath: "/Applications/WorkBuddy.app"),
        Target(name: "DeepSeek", bundleID: "com.deepseek.dsh", appPath: "/Applications/DeepSeek Harness.app")
    ]
    private var selected = 2
    private var recording = false
    private var tap: CFMachPort?
    private var retryTimer: Timer?
    private var statusItem: NSStatusItem?
    private var voiceTimeout: Timer?
    private var hud: NSPanel?
    private var hudLabel: NSTextField?
    private var hudGeneration = 0
    private var recordingInputBefore: String?
    private var pendingDictationBaseline: String?
    private let statePath = NSString(string: "~/Library/Application Support/VibeKeyBridge/selection.txt").expandingTildeInPath
    private let statusPath = NSString(string: "~/Library/Application Support/VibeKeyBridge/status.txt").expandingTildeInPath

    private func status(_ message: String) {
        try? FileManager.default.createDirectory(atPath: (statusPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? "\(Date()) \(message)\n".write(toFile: statusPath, atomically: true, encoding: .utf8)
        NSLog("VibeKeyBridge: %@", message)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let saved = try? String(contentsOfFile: statePath, encoding: .utf8), let n = Int(saved.trimmingCharacters(in: .whitespacesAndNewlines)), targets.indices.contains(n) {
            selected = n
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        refreshMenu()
        status("launched")
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(prompt)
        installTap()
        if tap == nil {
            retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in self.installTap() }
        }
    }

    private func installTap() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else {
            statusItem?.button?.title = "Vibe Key 授权"
            status("waiting for Accessibility")
            return
        }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, _ in
            guard type == .keyDown else { return Unmanaged.passUnretained(event) }
            let required: CGEventFlags = [.maskControl, .maskAlternate, .maskShift]
            guard event.flags.intersection(required) == required else { return Unmanaged.passUnretained(event) }
            let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let action: Int?
            switch key {
            case 18: action = 1  // 1: previous
            case 19: action = 2  // 2: next
            case 20: action = 3  // 3: wake
            case 21: action = 4  // 4: voice
            case 23: action = 5  // 5: approve
            case 22: action = 6  // 6: reject
            default: action = nil
            }
            guard let action else { return Unmanaged.passUnretained(event) }
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                DispatchQueue.main.async { Bridge.shared.perform(action) }
            }
            return nil
        }, userInfo: nil)
        guard let tap else {
            statusItem?.button?.title = "Vibe Key ⚠"
            status("keyboard access unavailable")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        retryTimer?.invalidate()
        retryTimer = nil
        refreshMenu()
        status("ready")
    }

    private func perform(_ action: Int) {
        switch action {
        case 1: choose((selected + targets.count - 1) % targets.count)
        case 2: choose((selected + 1) % targets.count)
        case 3: wake()
        case 4: toggleVoice()
        case 5: answerAuthorization(approve: true)
        case 6: answerAuthorization(approve: false)
        default: break
        }
    }

    private func choose(_ index: Int) {
        stopVoice()
        pendingDictationBaseline = nil
        selected = index
        try? FileManager.default.createDirectory(atPath: (statePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? String(selected).write(toFile: statePath, atomically: true, encoding: .utf8)
        refreshMenu()
        status("selected \(targets[selected].name)")
        showHUD("已选择 \(targets[selected].name) · 按下旋钮唤醒")
    }

    private func showHUD(_ message: String) {
        if hud == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 68), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .statusBar
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 380, height: 68))
            background.material = .hudWindow
            background.state = .active
            background.wantsLayer = true
            background.layer?.cornerRadius = 16
            background.layer?.masksToBounds = true
            let label = NSTextField(labelWithString: "")
            label.frame = NSRect(x: 16, y: 17, width: 348, height: 34)
            label.alignment = .center
            label.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
            label.textColor = .labelColor
            background.addSubview(label)
            panel.contentView = background
            hud = panel
            hudLabel = label
        }
        guard let hud, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        hudLabel?.stringValue = message
        hud.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 190, y: screen.visibleFrame.maxY - 125))
        NSApp.unhideWithoutActivation()
        hud.orderFrontRegardless()
        hudGeneration += 1
        let generation = hudGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            if self.hudGeneration == generation { self.hud?.orderOut(nil) }
        }
    }

    private func hideHUD() {
        hudGeneration += 1
        hud?.orderOut(nil)
    }

    private func refreshMenu() {
        statusItem?.button?.title = recording ? "🎙 \(targets[selected].name)" : "⌘ \(targets[selected].name)"
        let menu = NSMenu()
        for (index, target) in targets.enumerated() {
            let item = NSMenuItem(title: target.name, action: #selector(selectFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = selected == index ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Vibe Key 控制", action: #selector(quitBridge), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        statusItem?.menu = menu
    }

    @objc private func selectFromMenu(_ item: NSMenuItem) { choose(item.tag) }
    @objc private func quitBridge() { stopVoice(); NSApp.terminate(nil) }

    private func activateTarget(_ completion: @escaping () -> Void) {
        let target = targets[selected]
        hideHUD()
        let appPath = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleID)?.path ?? target.appPath
        guard FileManager.default.fileExists(atPath: appPath) else {
            status("missing application \(target.name)")
            showHUD("未找到 \(target.name)，请先安装应用")
            return
        }
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleID).isEmpty
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", appPath]
        try? process.run()
        let initialDelay = wasRunning ? 0.2 : 0.8
        func waitForFrontmost(_ attempts: Int) {
            guard self.targets[self.selected].bundleID == target.bundleID else { return }
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == target.bundleID {
                completion()
            } else if attempts > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { waitForFrontmost(attempts - 1) }
            } else {
                status("could not activate \(target.name)")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay) { waitForFrontmost(20) }
    }

    private func wake() {
        activateTarget {}
    }

    private func answerAuthorization(approve: Bool) {
        stopVoice()
        if approve, let baseline = pendingDictationBaseline {
            waitForDictation(baseline: baseline, attempts: 80)
            return
        }
        if !approve { pendingDictationBaseline = nil }
        let targetIndex = selected
        DispatchQueue.main.asyncAfter(deadline: .now()) {
          guard self.selected == targetIndex else { return }
          self.activateTarget {
            guard self.selected == targetIndex else { return }
            let target = self.targets[self.selected]
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleID).first,
                  let focusedValue = self.axValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute) else {
                self.sendDefaultKey(approve: approve)
                return
            }
            let focused = focusedValue as! AXUIElement
            var buttons: [(AXUIElement, String)] = []
            self.findButtons(in: focused, depth: 0, into: &buttons)
            let strongAllow = ["允许", "批准", "授权", "同意", "allow", "approve", "grant"]
            let strongDeny = ["拒绝", "否决", "不允许", "deny", "reject", "don't allow"]
            let allowWords = strongAllow + ["确认", "继续", "yes"]
            let denyWords = strongDeny + ["取消", "cancel", "no"]
            func matches(_ label: String, _ words: [String]) -> Bool {
                let normalized = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                return words.contains {
                    let chinese = $0.unicodeScalars.contains { $0.value > 127 }
                    return normalized == $0 || (chinese && normalized.hasPrefix($0)) || normalized.hasPrefix($0 + " ") || normalized.hasPrefix($0 + "（")
                }
            }
            let allowed = buttons.first { matches($0.1, allowWords) }
            let denied = buttons.first { matches($0.1, denyWords) }
            let authorizationLabelsPresent = buttons.contains { matches($0.1, strongAllow + strongDeny) }
            guard let allowed, let denied, authorizationLabelsPresent else {
                self.sendDefaultKey(approve: approve)
                return
            }
            let chosen = approve ? allowed : denied
            let result = AXUIElementPerformAction(chosen.0, kAXPressAction as CFString)
            if result == .success {
                self.status("authorization \(approve ? "approved" : "denied") in \(target.name)")
            } else {
                self.sendDefaultKey(approve: approve)
            }
          }
        }
    }

    private func waitForDictation(baseline: String, attempts: Int) {
        guard pendingDictationBaseline != nil else { return }
        if let current = focusedInputText(), current != baseline, !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pendingDictationBaseline = nil
            activateTarget { self.sendDefaultKey(approve: true) }
            return
        }
        if attempts == 0 {
            status("dictation did not reach \(targets[selected].name); message not sent")
            showHUD("语音尚未进入输入框，暂未发送")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.waitForDictation(baseline: baseline, attempts: attempts - 1)
        }
    }

    private func focusedInputText() -> String? {
        let target = targets[selected]
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleID).first else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused = axValue(root, kAXFocusedUIElementAttribute) as! AXUIElement? else { return nil }
        let role = String(describing: axValue(focused, kAXRoleAttribute) ?? "")
        guard role == "AXTextArea", target.bundleID == "com.tencent.workbuddy.mac" || isComposer(focused, for: target) else { return nil }
        return axValue(focused, kAXValueAttribute) as? String ?? ""
    }

    private func isComposer(_ field: AXUIElement, for target: Target) -> Bool {
        let title = String(describing: axValue(field, kAXTitleAttribute) ?? "")
        let description = String(describing: axValue(field, kAXDescriptionAttribute) ?? "")
        switch target.bundleID {
        case "com.deepseek.dsh": return description.contains("发消息或创建任务")
        case "com.anthropic.claudefordesktop": return description.contains("提示词")
        case "com.openai.codex": return title.contains("使用 ChatGPT Work")
        default: return true
        }
    }

    private func sendDefaultKey(approve: Bool) {
        if approve { focusInput() }
        sendKey(approve ? 36 : 53, flags: [])
        status(approve ? "message sent in \(targets[selected].name)" : "cancel sent in \(targets[selected].name)")
    }

    private func axValue(_ element: AXUIElement, _ key: String) -> Any? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }

    private func findButtons(in element: AXUIElement, depth: Int, into result: inout [(AXUIElement, String)]) {
        guard depth < 18 else { return }
        let role = String(describing: axValue(element, kAXRoleAttribute) ?? "")
        if role == "AXButton" {
            for label in buttonLabels(element, depth: 0) where !label.isEmpty {
                result.append((element, label))
            }
        }
        for child in axValue(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            findButtons(in: child, depth: depth + 1, into: &result)
        }
    }

    private func buttonLabels(_ element: AXUIElement, depth: Int) -> [String] {
        guard depth < 4 else { return [] }
        var labels: [String] = []
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            if let value = axValue(element, key) as? String, !value.isEmpty { labels.append(value) }
        }
        for child in axValue(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            labels += buttonLabels(child, depth: depth + 1)
        }
        return labels
    }

    private func focusInput() {
        let target = targets[selected]
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleID).first else { return }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        if let focusedValue = axValue(root, kAXFocusedUIElementAttribute) {
            let focused = focusedValue as! AXUIElement
            let role = String(describing: axValue(focused, kAXRoleAttribute) ?? "")
            if role == "AXTextArea" && isComposer(focused, for: target) { return }
        }
        guard let windowValue = axValue(root, kAXFocusedWindowAttribute) else { return }
        let window = windowValue as! AXUIElement
        var fields: [AXUIElement] = []
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 30 else { return }
            let role = String(describing: axValue(element, kAXRoleAttribute) ?? "")
            if role == "AXTextArea" { fields.append(element) }
            for child in axValue(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                walk(child, depth: depth + 1)
            }
        }
        walk(window, depth: 0)
        let preferred = fields.first { isComposer($0, for: target) } ?? fields.last
        if let preferred {
            _ = AXUIElementSetAttributeValue(preferred, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
    }

    private func sendKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func toggleVoice() {
        if recording { stopVoice(); return }
        activateTarget {
            self.focusInput()
            self.recordingInputBefore = self.focusedInputText()
            self.pendingDictationBaseline = nil
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: "now.typeless.desktop")
            if running.isEmpty {
                let typelessPath = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "now.typeless.desktop")?.path ?? "/Applications/Typeless.app"
                guard FileManager.default.fileExists(atPath: typelessPath) else {
                    self.status("Typeless not installed")
                    self.showHUD("未找到听写工具 Typeless")
                    return
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-gj", "-a", typelessPath]
                try? process.run()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (running.isEmpty ? 1.0 : 0.1)) {
                self.recording = true
                self.sendRightOptionTap()
                self.refreshMenu()
                self.voiceTimeout = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { _ in self.stopVoice() }
                NSLog("VibeKeyBridge: dictation started")
            }
        }
    }

    private func stopVoice() {
        guard recording else { return }
        sendRightOptionTap()
        recording = false
        pendingDictationBaseline = recordingInputBefore
        recordingInputBefore = nil
        voiceTimeout?.invalidate()
        voiceTimeout = nil
        refreshMenu()
        NSLog("VibeKeyBridge: dictation stopped")
    }

    private func sendRightOptionTap() {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 61, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 61, keyDown: false)
        down?.flags = .maskAlternate
        up?.flags = []
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    func applicationWillTerminate(_ notification: Notification) { stopVoice() }
}

let app = NSApplication.shared
app.delegate = Bridge.shared
app.run()
