import Cocoa
import WebKit
import Network

// cc-network 菜单栏监控 App (LSUIElement)
// 自包含: 检测脚本打包在 App 内，数据写入用户的 Application Support 目录。

// 数据目录: ~/Library/Application Support/cc
let baseDir: String = {
    let appSup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let dir = ProcessInfo.processInfo.environment["CC_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? appSup.appendingPathComponent("cc")
    let fm = FileManager.default
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.path
}()
let statusPath = (baseDir as NSString).appendingPathComponent("status")
let claudeStatusPath = (baseDir as NSString).appendingPathComponent("claude_status")
let claudeProbeStatePath = (baseDir as NSString).appendingPathComponent("claude_probe_state")
let browserPath = (baseDir as NSString).appendingPathComponent("browser_signals")
let logPath = (baseDir as NSString).appendingPathComponent("cc-network.log")
let networkHistoryPath = (baseDir as NSString).appendingPathComponent("network_history")
// 检测脚本: 优先用 App 包内 Resources 里的，开发时回退到源码目录
func script(_ name: String) -> String {
    Bundle.main.path(forResource: name, ofType: "sh")
        ?? (NSHomeDirectory() as NSString).appendingPathComponent("cc/\(name).sh")
}
let scriptPath = script("cc-network")
let claudeScriptPath = script("cc-check")

// 地区标题只接受本轮第三路确认的时区；历史时区仅在详情展示。
func currentRegionTitle(_ status: [String: String], now: TimeInterval = Date().timeIntervalSince1970) -> String {
    guard let epoch = Double(status["probe_epoch"] ?? ""), now - epoch <= 300 else { return "地区待确认" }
    if status["region_state"] == "verifying" { return "地区复核中" }
    guard status["region_state"] == "ok", let ip = status["gfw"], ip != "?",
          !ip.isEmpty, ip == status["timezone_ip"],
          let timezone = status["gfwtz"], TimeZone(identifier: timezone) != nil else { return "地区待确认" }
    return timezone.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? "地区待确认"
}

// IPv6 出口只展示 cc-check 写入的地址、归属和来源；旧版状态文件没有来源字段时提示重新体检。
func ipv6Summary(_ c: [String: String]) -> String {
    switch c["ipv6status"] ?? "" {
    case "none": return "无 IPv6 出口（无泄漏面）"
    case "failed": return "探测未完成，暂无法确认"
    case "ok":
        let country = c["ipv6country"].flatMap { $0.isEmpty || $0 == "?" ? nil : $0 } ?? "归属未知"
        let origin: String
        switch c["ipv6origin"] ?? "" {
        case "local": origin = "本机地址，未经代理"
        case "upstream": origin = "非本机地址，来自代理节点或上游"
        default: origin = "来源未知"
        }
        return "\(c["ipv6"] ?? "?") · \(country) · \(origin)"
    default: return "未区分来源，请重新体检"
    }
}

// 单条评分复核只补测一次；计时与任务状态独立于出口 IP 是否变化。
struct ScoreReviewRetry {
    private(set) var key = ""
    var attemptedKey = ""
    private(set) var observedAt: TimeInterval = 0
    private(set) var runningKey: String?
    private(set) var startedAt: TimeInterval = 0

    mutating func observe(_ record: [String: String], now: TimeInterval) {
        guard record["state"] == "verifying" else { key = ""; return }
        let next = ["time", "failure_count", "candidate_score", "detail"].map { record[$0] ?? "" }.joined(separator: "|")
        guard next != key else { return }
        key = next
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        observedAt = min(now, format.date(from: record["time"] ?? "")?.timeIntervalSince1970 ?? now)
    }

    func shouldRetry(now: TimeInterval, busy: Bool) -> Bool {
        !key.isEmpty && runningKey == nil && key != attemptedKey && now - observedAt >= 30 && !busy
    }

    mutating func begin(now: TimeInterval) {
        attemptedKey = key; runningKey = key; startedAt = now
    }

    mutating func finish() { runningKey = nil }

    func label(now: TimeInterval) -> String? {
        guard !key.isEmpty else { return nil }
        if runningKey == key { return now - startedAt <= 300 ? "复核中" : "复核未完成" }
        if attemptedKey == key || now - observedAt > 300 { return "复核未完成" }
        return "待复核"
    }
}

enum NetworkRoute: CaseIterable {
    case cn, intl, gfw, google

    var title: String {
        switch self {
        case .cn: return "国内"
        case .intl: return "国外"
        case .gfw: return "谷歌侧"
        case .google: return "Google"
        }
    }

    var color: NSColor {
        switch self {
        case .cn: return .systemBlue
        case .intl: return .systemTeal
        case .gfw: return .systemPurple
        case .google: return .systemGreen
        }
    }
}

struct HTTPSRouteSample {
    let totalSeconds: Double
    let succeeded: Bool
    let connectSeconds: Double
    let tlsSeconds: Double
    let ttfbSeconds: Double
    let httpCode: Int

    var hasDetailedTiming: Bool {
        httpCode > 0 || connectSeconds > 0 || tlsSeconds > 0 || ttfbSeconds > 0
    }
}

struct NetworkHistoryPoint {
    let timestamp: TimeInterval
    let totalSeconds: Double
    let result: String
    let ip: String
    let ipChanged: Bool
    let cn: HTTPSRouteSample
    let intl: HTTPSRouteSample
    let gfw: HTTPSRouteSample
    let google: HTTPSRouteSample

    func sample(for route: NetworkRoute) -> HTTPSRouteSample {
        switch route {
        case .cn: return cn
        case .intl: return intl
        case .gfw: return gfw
        case .google: return google
        }
    }

    func seconds(for route: NetworkRoute) -> Double { sample(for: route).totalSeconds }
    func succeeded(_ route: NetworkRoute) -> Bool { sample(for: route).succeeded }
}

// NSMenu 没有原生图表控件，用一个只读 NSView 画四路小趋势图。
// 每一路独立折线，能直接看出是国内、国外、谷歌侧还是 Google 连通性在失败。
final class NetworkHistoryView: NSView {
    private let points: [NetworkHistoryPoint]
    private var hoverIndex: Int?
    private var hoverTrackingArea: NSTrackingArea?
    private let chartLeft: CGFloat = 54
    private let chartRight: CGFloat = 10
    private let chartTop: CGFloat = 24
    private let chartRowHeight: CGFloat = 18.5

    init(points: [NetworkHistoryPoint]) {
        self.points = points
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: 430, height: 138)))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(accessibilitySummary())
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    private func accessibilitySummary() -> String {
        guard !points.isEmpty else { return "网络波动图，暂无历史数据" }
        let routeText = NetworkRoute.allCases.map { route in
            let failures = points.filter { !$0.succeeded(route) }.count
            return "\(route.title)失败\(failures)次"
        }.joined(separator: "，")
        let changes = points.filter(\.ipChanged).count
        return "最近\(points.count)次线路检测，\(routeText)，确认换IP\(changes)次"
    }

    private func drawText(_ text: String, at point: NSPoint, font: NSFont, color: NSColor) {
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }

    private var plotWidth: CGFloat { max(1, bounds.width - chartLeft - chartRight) }
    private var plotBottom: CGFloat { chartTop + chartRowHeight * CGFloat(NetworkRoute.allCases.count) }

    private func xPosition(_ index: Int) -> CGFloat {
        guard points.count > 1 else { return chartLeft + plotWidth }
        return chartLeft + CGFloat(index) * plotWidth / CGFloat(points.count - 1)
    }

    private func durationText(_ point: NetworkHistoryPoint, route: NetworkRoute) -> String {
        guard point.succeeded(route) else { return "失败" }
        let seconds = point.seconds(for: route)
        return seconds < 1 ? "\(Int((seconds * 1000).rounded()))ms" : String(format: "%.2fs", seconds)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func mouseMoved(with event: NSEvent) {
        guard !points.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard point.x >= chartLeft, point.x <= chartLeft + plotWidth,
              point.y >= chartTop - 4, point.y <= bounds.height else {
            if hoverIndex != nil { hoverIndex = nil; needsDisplay = true }
            return
        }
        let ratio = max(0, min(1, (point.x - chartLeft) / plotWidth))
        let index = points.count == 1 ? 0 : Int((ratio * CGFloat(points.count - 1)).rounded())
        if hoverIndex != index { hoverIndex = index; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        hoverIndex = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let titleFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let labelFont = NSFont.systemFont(ofSize: 9.5, weight: .medium)
        let noteFont = NSFont.systemFont(ofSize: 9)
        drawText("最近 \(points.count) 次线路延迟", at: NSPoint(x: 8, y: 5),
                 font: titleFont, color: .labelColor)

        guard !points.isEmpty else {
            drawText("暂无历史数据，完成一次出口检测后显示", at: NSPoint(x: 52, y: bounds.midY - 7),
                     font: NSFont.systemFont(ofSize: 11), color: .secondaryLabelColor)
            return
        }


        // 已确认的换 IP 用贯穿四路的红线标记，和单路接口失败区分开。
        NSColor.systemRed.withAlphaComponent(0.55).setStroke()
        for (index, point) in points.enumerated() where point.ipChanged {
            let x = xPosition(index)
            let marker = NSBezierPath()
            marker.move(to: NSPoint(x: x, y: chartTop))
            marker.line(to: NSPoint(x: x, y: plotBottom))
            marker.lineWidth = 1.2
            marker.stroke()
        }

        for (routeIndex, route) in NetworkRoute.allCases.enumerated() {
            let rowTop = chartTop + CGFloat(routeIndex) * chartRowHeight
            let rowBottom = rowTop + chartRowHeight - 4
            let baseline = NSBezierPath()
            baseline.move(to: NSPoint(x: chartLeft, y: rowBottom))
            baseline.line(to: NSPoint(x: chartLeft + plotWidth, y: rowBottom))
            NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
            baseline.lineWidth = 0.5
            baseline.stroke()

            drawText(route.title, at: NSPoint(x: 8, y: rowTop + 3), font: labelFont, color: route.color)

            let successfulDurations = points.filter { $0.succeeded(route) }.map { max(0.01, $0.seconds(for: route)) }.sorted()
            let percentileIndex = max(0, Int(Double(max(0, successfulDurations.count - 1)) * 0.95))
            let p95 = successfulDurations.isEmpty ? 0.1 : successfulDurations[percentileIndex]
            let maxScale = max(0.1, p95 * 1.25)
            let amplitude = max(3, chartRowHeight - 8)
            let path = NSBezierPath()
            var previousSucceeded = false

            for (index, point) in points.enumerated() {
                let x = xPosition(index)
                if point.succeeded(route) {
                    let value = min(maxScale, max(0.01, point.seconds(for: route)))
                    let y = rowBottom - CGFloat(value / maxScale) * amplitude
                    if previousSucceeded { path.line(to: NSPoint(x: x, y: y)) }
                    else { path.move(to: NSPoint(x: x, y: y)) }
                    let dot = NSBezierPath(ovalIn: NSRect(x: x - 1.2, y: y - 1.2, width: 2.4, height: 2.4))
                    route.color.setFill()
                    dot.fill()
                    previousSucceeded = true
                } else {
                    previousSucceeded = false
                    let dot = NSBezierPath(ovalIn: NSRect(x: x - 2.2, y: rowBottom - amplitude / 2 - 2.2, width: 4.4, height: 4.4))
                    NSColor.systemOrange.setFill()
                    dot.fill()
                }
            }
            route.color.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 1.25
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            path.stroke()
        }

        drawText("折线=总耗时   橙点=失败   红线=已确认换 IP",
                 at: NSPoint(x: chartLeft, y: plotBottom + 3), font: noteFont, color: .secondaryLabelColor)
        if let hoverIndex, points.indices.contains(hoverIndex) {
            let selected = points[hoverIndex]
            let guide = NSBezierPath()
            let x = xPosition(hoverIndex)
            guide.move(to: NSPoint(x: x, y: chartTop))
            guide.line(to: NSPoint(x: x, y: plotBottom))
            NSColor.labelColor.withAlphaComponent(0.45).setStroke()
            guide.lineWidth = 0.8
            guide.stroke()

            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            let time = formatter.string(from: Date(timeIntervalSince1970: selected.timestamp))
            let values = NetworkRoute.allCases.map { "\($0.title) \(durationText(selected, route: $0))" }.joined(separator: "  ")
            drawText("\(time)  \(values)", at: NSPoint(x: 8, y: plotBottom + 18),
                     font: noteFont, color: .labelColor)
        } else {
            drawText("鼠标移到曲线上查看每次延迟", at: NSPoint(x: 8, y: plotBottom + 18),
                     font: noteFont, color: .tertiaryLabelColor)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var uiTimer: Timer?
    var scanTimer: Timer?
    var scanProcess: Process?   // 同一时间只允许一个出口检测，避免旧结果覆盖新结果
    var scoreReview = ScoreReviewRetry(attemptedKey: UserDefaults.standard.string(forKey: "scoreReviewAttemptedKey") ?? "")
    var lastExitIP = ""      // 出口 IP 变化时才重跑 Claude 环境体检
    var probe: BrowserProbe?
    var bridge: BrowserBridge?
    var phase: String?          // 非 nil = 正在检测(内部分两步，不暴露给用户)

    // 菜单栏 App 没有窗口，用户双击一个已在运行的实例时系统什么都不显示，
    // 很容易被当成「打不开」。给一条通知，指回菜单栏图标。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        notify("cc 已在运行", "点菜单栏右上角的图标查看体检结果")
        return true
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        item.menu = NSMenu()
        item.behavior = .removalAllowed
        // 遗留复核优先复用已有浏览器数据，不因启动而重新打开浏览器。
        if readStatus(claudeProbeStatePath)["state"] == "verifying" {
            lastExitIP = readStatus(claudeStatusPath)["ip"] ?? ""
        }
        refresh()
        notify("cc已启动", "图标在屏幕右上角菜单栏 🌐，点击查看出口IP与时区")
        runScript(["--check"], isScan: true) // 启动即检测一次
        // 每 30 秒读快照刷新显示
        uiTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // 定时主动检测(默认 1 分钟，可在菜单"检测间隔"调整)
        startScanTimer()
    }

    // 当前检测间隔(秒)，默认 60
    func scanInterval() -> Double {
        let v = UserDefaults.standard.double(forKey: "scanInterval")
        return v > 0 ? v : 60
    }

    func startScanTimer() {
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: scanInterval(), repeats: true) { [weak self] _ in
            self?.runScript(["--check"], isScan: true)
        }
    }

    @objc func setInterval(_ sender: NSMenuItem) {
        UserDefaults.standard.set(Double(sender.tag), forKey: "scanInterval")
        startScanTimer()
        refresh()
    }

    func runScript(_ args: [String], _ path: String = scriptPath, isScan: Bool = false,
                   then: ((Int32) -> Void)? = nil) {
        // 定时器、启动检测和“立即检测”可能同时触发。出口检测只保留一个进程；
        // shell 侧还有跨进程锁，防止 launchd 或其它入口与 App 竞争写状态。
        if isScan, scanProcess != nil || phase == "评分复核" { return }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [path] + args
        var env = ProcessInfo.processInfo.environment
        env["CC_DATA_DIR"] = baseDir   // 与脚本共用同一数据目录
        env["CC_GUI"] = "1"  // 对话框由 App 统一展示，避免 shell 重复弹窗
        p.environment = env
        if isScan { scanProcess = p }
        p.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                if isScan { self?.scanProcess = nil }
                self?.refresh()
                then?(process.terminationStatus)
            }
        }
        do {
            try p.run()
        } catch {
            if isScan { scanProcess = nil }
            refresh()
            then?(-1)
        }
    }

    func notify(_ title: String, _ msg: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(msg)\" with title \"\(title)\""]
        try? p.run()
    }

    func readStatus(_ path: String = statusPath) -> [String: String] {
        guard let txt = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var d: [String: String] = [:]
        for line in txt.split(separator: "\n") {
            if let eq = line.firstIndex(of: "=") {
                d[String(line[..<eq])] = String(line[line.index(after: eq)...])
            }
        }
        return d
    }

    func browserReportPayload() -> [String: Any] {
        let history = readNetworkHistory()
        let quality: [String: Any]
        if let latest = history.last {
            func route(_ value: NetworkRoute) -> [String: Any] {
                let sample = latest.sample(for: value)
                let successes = history.filter { $0.succeeded(value) }
                let totals = successes.map { $0.seconds(for: value) }
                let average = totals.isEmpty ? 0 : totals.reduce(0, +) / Double(totals.count)
                let deltas = zip(totals.dropFirst(), totals).map { abs($0 - $1) }
                let jitter = deltas.isEmpty ? 0 : deltas.reduce(0, +) / Double(deltas.count)
                return [
                    "ok": sample.succeeded,
                    "http": sample.httpCode,
                    "total": sample.totalSeconds,
                    "connect": sample.connectSeconds,
                    "tls": sample.tlsSeconds,
                    "ttfb": sample.ttfbSeconds,
                    "successRate": history.isEmpty ? 0 : Int((Double(successes.count) * 100 / Double(history.count)).rounded()),
                    "failures": history.count - successes.count,
                    "average": average,
                    "jitter": jitter,
                ]
            }
            quality = [
                "samples": history.count,
                "ipChanges": history.filter(\.ipChanged).count,
                "cn": route(.cn), "intl": route(.intl), "gfw": route(.gfw), "google": route(.google),
            ]
        } else {
            quality = ["samples": 0, "ipChanges": 0]
        }
        return [
            "ready": true,
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "network": readStatus(statusPath),
            "claude": readStatus(claudeStatusPath),
            "browser": readStatus(browserPath),
            "probe": readStatus(claudeProbeStatePath),
            "quality": quality,
        ]
    }

    func readNetworkHistory() -> [NetworkHistoryPoint] {
        guard let txt = try? String(contentsOfFile: networkHistoryPath, encoding: .utf8) else { return [] }
        let now = Date().timeIntervalSince1970
        let cutoff = now - 24 * 3600
        return txt.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 13,
                  let timestamp = TimeInterval(f[0]), timestamp >= cutoff, timestamp <= now + 300,
                  let total = Double(f[1]),
                  let cnSeconds = Double(f[5]), let cnOK = Int(f[6]),
                  let intlSeconds = Double(f[7]), let intlOK = Int(f[8]),
                  let gfwSeconds = Double(f[9]), let gfwOK = Int(f[10]),
                  let googleSeconds = Double(f[11]), let googleOK = Int(f[12]) else { return nil }

            func number(_ index: Int) -> Double {
                guard index < f.count else { return 0 }
                return Double(f[index]) ?? 0
            }
            func code(_ index: Int) -> Int {
                guard index < f.count else { return 0 }
                return Int(f[index]) ?? 0
            }
            func sample(total: Double, ok: Int, metricsAt index: Int) -> HTTPSRouteSample {
                HTTPSRouteSample(totalSeconds: total, succeeded: ok == 1,
                                 connectSeconds: number(index), tlsSeconds: number(index + 1),
                                 ttfbSeconds: number(index + 2), httpCode: code(index + 3))
            }

            return NetworkHistoryPoint(timestamp: timestamp, totalSeconds: total, result: f[2], ip: f[3],
                                       ipChanged: f[4] == "1",
                                       cn: sample(total: cnSeconds, ok: cnOK, metricsAt: 13),
                                       intl: sample(total: intlSeconds, ok: intlOK, metricsAt: 17),
                                       gfw: sample(total: gfwSeconds, ok: gfwOK, metricsAt: 21),
                                       google: sample(total: googleSeconds, ok: googleOK, metricsAt: 25))
        }.sorted { $0.timestamp < $1.timestamp }
    }

    func refresh() {
        let s = readStatus()
        let consistent = s["consistent"] ?? ""
        let network = s["network"] ?? "ok"   // 旧版快照没有该字段，按稳定处理
        let history = readNetworkHistory()
        let tz = s["tz"] ?? "?"
        let timezoneIP = s["timezone_ip"] ?? ""
        let timezoneSynced = s["timezone_synced"] ?? "?"
        let timezoneDetail = s["timezone_detail"] ?? ""

        let city = currentRegionTitle(s)
        let regionConfirmed = s["region_state"] == "ok" && city != "地区待确认"
        // 图标要反映"这台机器现在能不能安全跑 Claude"，而不只是三路 IP 一致性 ——
        // 光看 IP 一致但分数掉到 60 分，图标还是绿的，等于没提醒。
        let cs = readStatus(claudeStatusPath)
        let cps = readStatus(claudeProbeStatePath)
        scoreReview.observe(cps, now: Date().timeIntervalSince1970)
        let claudeScore = Int(cs["score"] ?? "") ?? -1
        let scoreVerifying = cps["state"] == "verifying"
        let safe = claudeScore >= 90 && consistent == "1" && network == "ok" && timezoneSynced != "0" && regionConfirmed
        // 网络结果还在复核时不改变安全档位，也不发送“不可用/恢复”通知。
        if network == "ok" && regionConfirmed && !scoreVerifying {
            alertIfUnsafe(claudeScore, consistent: consistent, verdict: cs["verdict"] ?? "")
        }

        if let btn = item.button {
            // 综合判定: 安全=绿勾 / 有隐患=黄感叹号 / 不建议使用=红叉 / 无数据=灰问号
            let symName: String
            let color: NSColor
            if claudeScore < 0 && s.isEmpty { symName = "questionmark.circle"; color = .systemGray }
            else if network != "ok" { symName = "exclamationmark.triangle.fill"; color = .systemOrange }
            else if safe { symName = "checkmark.circle.fill"; color = .systemGreen }
            else if claudeScore >= 70 && consistent == "1" { symName = "exclamationmark.triangle.fill"; color = .systemOrange }
            else { symName = "xmark.circle.fill"; color = .systemRed }
            // 颜色只作用在勾/叉图标上(paletteColors)，不用 contentTintColor 以免染到文字
            let conf = NSImage.SymbolConfiguration(paletteColors: [color])
            let img = NSImage(systemSymbolName: symName, accessibilityDescription: "出口IP状态")?
                .withSymbolConfiguration(conf)
            img?.isTemplate = false
            btn.image = img
            btn.imagePosition = .imageLeading
            btn.contentTintColor = nil                          // 文字保持系统默认色，与其它菜单栏文字一致
            let location = city.isEmpty ? " cc" : " \(city)"
            btn.title = location + "  ›"
        }

        let menu = NSMenu()
        menu.addItem(disabled("cc · 仅检测，修复需确认"))
        menu.addItem(.separator())
        let head: String
        switch network {
        case "unstable": head = consistent == "0" ? "检测到出口分流（检测未完整）⚠️" : "出口检测未完成 ⚠️"
        case "verifying": head = consistent == "0" ? "检测到出口分流（复核中）⚠️" : "出口探测结果复核中…"
        default: head = consistent == "1" ? "出口 IP 一致 ✅" : (s.isEmpty ? "尚无检测数据" : "出口 IP 异常 ⚠️")
        }
        if s.isEmpty {
            menu.addItem(disabled(head))
        } else if network != "ok" {
            menu.addItem(colored(head, .systemOrange))
        } else if consistent == "1" {
            menu.addItem(colored(head, .systemGreen))
        } else {
            menu.addItem(colored(head, .systemRed))
        }

        let failures = Int(s["failure_count"] ?? "0") ?? 0
        let confirmations = Int(s["confirm_count"] ?? "0") ?? 0
        let required = Int(s["confirm_required"] ?? "2") ?? 2
        let networkLine: String
        if network == "unstable" {
            networkLine = "探测状态: 接口波动（连续失败 \(failures) 次，本轮结果未完整）"
        } else if network == "verifying", failures > 0 {
            networkLine = "探测状态: 单次接口波动（\(failures)/\(required)，本轮结果未完整）"
        } else if network == "verifying" {
            networkLine = "出口状态: 正在复核（\(confirmations)/\(required)，本轮结果未完整）"
        } else if s.isEmpty {
            networkLine = "探测状态: 尚未检测"
        } else {
            networkLine = "探测状态: 正常"
        }
        menu.addItem(disabled(networkLine))
        if let latest = history.last {
            let failedRoutes = NetworkRoute.allCases.filter { !latest.succeeded($0) }.map(\.title)
            if !failedRoutes.isEmpty {
                menu.addItem(disabled("波动位置: \(failedRoutes.joined(separator: "、"))"))
            } else if latest.result == "inconsistent" {
                menu.addItem(disabled("波动位置: 三路出口结果不一致"))
            }
        }
        if let last = s["last_success"], !last.isEmpty {
            menu.addItem(disabled("上次完整确认: \(last) · \(s["last_confirmed_ip"] ?? "?")（历史参考）"))
        }
        menu.addItem(networkHistoryMenuItem(history))
        menu.addItem(.separator())
        menu.addItem(disabled("国内视角: \(s["cn"] ?? "?")"))
        menu.addItem(disabled("国外视角: \(s["intl"] ?? "?")"))
        menu.addItem(disabled("谷歌/被封: \(s["gfw"] ?? "?")  (Google: \(s["google"] ?? "?"))"))
        menu.addItem(.separator())
        let timezoneTarget = s["gfwtz"] ?? "?"
        let authority = timezoneIP.isEmpty ? "待确认" : timezoneIP
        if regionConfirmed {
            menu.addItem(disabled("本轮出口时区: \(authority) → \(timezoneTarget)"))
        } else {
            menu.addItem(disabled("地区状态: \(currentRegionTitle(s))"))
            menu.addItem(disabled("历史出口时区: \(authority) → \(timezoneTarget)（仅供参考）"))
            menu.addItem(disabled("历史地区确认时间: \(s["region_last_success"] ?? "未知")"))
        }
        if !regionConfirmed {
            menu.addItem(disabled("系统时区: \(tz)（出口地区待确认）"))
        } else if timezoneSynced == "1" {
            menu.addItem(plain("系统时区: \(tz)  已匹配 ✓"))
        } else if timezoneSynced == "0" {
            menu.addItem(plain("系统时区: \(tz)  未匹配，修复需确认 ⚠"))
        } else {
            menu.addItem(disabled("系统时区: \(tz)"))
        }
        if !timezoneDetail.isEmpty {
            menu.addItem(disabled("时区状态: \(timezoneDetail)"))
        }
        // 时间戳跟着系统时区走，而系统时区跟着出口走 —— 出口回到国内时它就是本地时间
        let exitCC = cs["country"] ?? ""
        menu.addItem(disabled("\(exitCC == "CN" ? "本地时间" : "海外时间"): \(s["time"] ?? "—")"))
        menu.addItem(.separator())

        menu.addItem(.separator())
        menu.addItem(claudeMenuItem())
        // 体检和修复都放主菜单一级，不藏进子菜单(子菜单只放明细)
        let c = cs
        if phase != nil {
            menu.addItem(disabled("正在检测…"))
        } else {
            menu.addItem(action("重新体检", #selector(runClaudeCheck)))
        }
        // 有自动项时直接修；只有手动项时按钮仍可点击，运行后给出可执行步骤。
        let gainRows = (c["gains"] ?? "").split(separator: "|").map(String.init)
        if c["fixable"] == "1", let list = c["fixlist"], !list.isEmpty {
            menu.addItem(action("⚡ 一键修复：\(list)", #selector(runClaudeFix)))
        } else if !c.isEmpty, !gainRows.isEmpty {
            menu.addItem(action("⚡ 一键修复 / 查看方案（\(gainRows.count) 项）", #selector(runClaudeFix)))
        } else if !c.isEmpty {
            menu.addItem(disabled("⚡ 一键修复（已满分，无需修复）"))
        }

        // 手动处理步骤只排除当前确实能自动处理的项，不再把“代理形态/DNS”一概隐藏。
        let fixList = c["fixlist"] ?? ""
        let actualAutoFixable: Set<String> = [
            fixList.contains("时区") ? "系统时区匹配出口" : "",
            fixList.contains("系统区域") ? "系统区域匹配出口" : "",
            fixList.contains("DNS") ? "DNS 出口" : "",
            fixList.contains("PAC") ? "代理形态" : "",
        ]
        let manual = gainRows.compactMap { g -> [String]? in
            let f = g.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3, !actualAutoFixable.contains(f[0]) else { return nil }
            return f
        }
        if !manual.isEmpty {
            let mi = NSMenuItem(title: "📋 手动处理步骤（\(manual.count) 项）", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for f in manual {
                sub.addItem(colored("\(f[0])   +\(f[1]) 分", .labelColor))
                // 步骤按分号折行，太长的菜单项会被系统截断
                for (i, part) in f[2].components(separatedBy: "；").enumerated() {
                    sub.addItem(disabled("      \(i == 0 ? "" : "或 ")\(part)"))
                }
                sub.addItem(.separator())
            }
            if manual.contains(where: { ["浏览器语言", "Intl 区域设置", "HTTP 语言首标"].contains($0[0]) }) {
                sub.addItem(action("打开浏览器语言设置", #selector(openBrowserLanguageSettings)))
                sub.addItem(.separator())
            }
            sub.addItem(action("重新体检", #selector(runClaudeCheck)))
            mi.submenu = sub
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        if scanProcess != nil {
            menu.addItem(disabled("正在检测出口…"))
        } else {
            menu.addItem(action("立即检测（不含浏览器）", #selector(runCheck)))
        }
        // 检测间隔子菜单
        let intervalMenu = NSMenu()
        for (label, secs) in [("1 分钟", 60), ("2 分钟", 120), ("5 分钟", 300), ("10 分钟", 600)] {
            let mi = NSMenuItem(title: label, action: #selector(setInterval(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = secs
            mi.state = (Int(scanInterval()) == secs) ? .on : .off
            intervalMenu.addItem(mi)
        }
        let intervalItem = NSMenuItem(title: "检测间隔", action: nil, keyEquivalent: "")
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)
        menu.addItem(action("打开日志", #selector(openLog)))
        menu.addItem(.separator())
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        menu.addItem(disabled("版本 v\(ver)（本地开发版）"))
        menu.addItem(.separator())
        menu.addItem(action("上游项目官方网站", #selector(openYinso)))
        menu.addItem(action("退出", #selector(quit)))
        item.menu = menu

        autoCheckIfExitChanged(s)
        resumeScoreReview()
    }

    func networkHistoryMenuItem(_ history: [NetworkHistoryPoint]) -> NSMenuItem {
        let recent = Array(history.suffix(60))
        let title = history.isEmpty ? "线路质量（暂无数据）" : "线路质量（最近 \(recent.count) 次）"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let chartItem = NSMenuItem()
        chartItem.view = NetworkHistoryView(points: recent)
        submenu.addItem(chartItem)
        submenu.addItem(.separator())

        if history.isEmpty {
            submenu.addItem(disabled("24 小时内暂无线路检测记录"))
        } else {
            let changes = history.filter(\.ipChanged).count
            submenu.addItem(disabled("24 小时统计: \(history.count) 次检测 · 确认换 IP \(changes) 次"))
            for route in NetworkRoute.allCases {
                submenu.addItem(disabled(routeSummary(route, history: history)))
                submenu.addItem(disabled(routeTimingSummary(route, history: history)))
            }
        }
        item.submenu = submenu
        return item
    }

    func formatNetworkDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        if seconds < 1 { return "\(Int((seconds * 1000).rounded()))ms" }
        return String(format: "%.2fs", seconds)
    }

    func routeSummary(_ route: NetworkRoute, history: [NetworkHistoryPoint]) -> String {
        let successes = history.filter { $0.succeeded(route) }
        let failures = history.count - successes.count
        let rate = history.isEmpty ? 0 : Int((Double(successes.count) * 100 / Double(history.count)).rounded())
        let totals = successes.map { $0.seconds(for: route) }
        let average = totals.isEmpty ? 0 : totals.reduce(0, +) / Double(totals.count)
        let deltas = zip(totals.dropFirst(), totals).map { abs($0 - $1) }
        let jitter = deltas.isEmpty ? 0 : deltas.reduce(0, +) / Double(deltas.count)
        let averageText = totals.isEmpty ? "—" : formatNetworkDuration(average)
        let jitterText = totals.count < 2 ? "—" : formatNetworkDuration(jitter)
        return "\(route.title): \(rate)% 成功 · 失败 \(failures) · HTTPS \(averageText) · 抖动 \(jitterText)"
    }

    func routeTimingSummary(_ route: NetworkRoute, history: [NetworkHistoryPoint]) -> String {
        let samples = history.map { $0.sample(for: route) }.filter { $0.succeeded && $0.hasDetailedTiming }
        guard !samples.isEmpty else { return "    TCP/TLS/TTFB: 旧版记录未采集" }
        func average(_ value: (HTTPSRouteSample) -> Double) -> Double {
            samples.reduce(0) { $0 + value($1) } / Double(samples.count)
        }
        let latestCode = samples.last?.httpCode ?? 0
        return "    TCP \(formatNetworkDuration(average { $0.connectSeconds })) · TLS \(formatNetworkDuration(average { $0.tlsSeconds })) · TTFB \(formatNetworkDuration(average { $0.ttfbSeconds })) · HTTP \(latestCode)"
    }

    func disabled(_ t: String) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    // 使用系统原生菜单文字颜色。被蓝色选中时 AppKit 会自动切换成白色，
    // 避免固定绿/橙色 attributedTitle 在选中态下对比度不足。
    func plain(_ t: String) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: #selector(noop), keyEquivalent: "")
        i.target = self
        return i
    }
    // disabled 项的 attributedTitle 会被系统统一压成灰色，所以要上色就必须是 enabled 的，
    // 没有实际动作的就绑一个空 selector。
    func colored(_ t: String, _ color: NSColor, _ sel: Selector? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: sel ?? #selector(noop), keyEquivalent: "")
        i.target = self
        i.attributedTitle = NSAttributedString(string: t, attributes: [
            .foregroundColor: color,
            .font: NSFont.menuFont(ofSize: 0)
        ])
        return i
    }
    @objc func noop() {}

    func action(_ t: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    // 状态跌到"不建议使用"时主动弹通知 —— 用户不会一直盯着菜单栏图标。
    // 只在档位变化时弹，同一档不重复打扰。
    var lastSafetyTier = ""
    func alertIfUnsafe(_ score: Int, consistent: String, verdict: String) {
        guard score >= 0 else { return }
        let tier: String
        if score >= 90 && consistent == "1" { tier = "safe" }
        else if score >= 70 && consistent == "1" { tier = "warn" }
        else { tier = "unsafe" }

        defer { lastSafetyTier = tier }
        guard !lastSafetyTier.isEmpty, tier != lastSafetyTier else { return }

        switch tier {
        case "unsafe":
            notify("⚠️ 不建议使用 Claude", verdict.isEmpty ? "环境 \(score) 分，存在安全风险，点菜单栏查看" : verdict)
        case "warn":
            // 用户的标准是二元的: 不是绿色就别用。橙档虽然比红档轻，措辞一样不留余地。
            notify("⚠️ 不建议使用 Claude", "环境 \(score) 分存在隐患，点菜单栏看还差哪几项")
        default:
            notify("Claude 环境已恢复", "\(score) 分，可以正常使用")
        }
    }

    // ── Claude 环境体检 ──────────────────────────────────────────
    // 出口 IP 变了才自动重测(环境画像只跟着出口走)，避免每分钟去敲 anthropic API
    func autoCheckIfExitChanged(_ s: [String: String]) {
        guard (s["network"] ?? "ok") == "ok" else { return }
        let ip = s["gfw"] ?? ""
        guard !ip.isEmpty, ip != "?" else { return }
        if ip != lastExitIP {
            lastExitIP = ip
            fullCheck()
        }
    }

    func resumeScoreReview() {
        let busy = phase != nil || bridge != nil || probe != nil || scanProcess != nil
        guard scoreReview.shouldRetry(now: Date().timeIntervalSince1970, busy: busy) else { return }
        phase = "等待评分复核"
        // 异步进入，避免在构建菜单的 refresh 调用栈内再次刷新。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 启动检测可能在此期间取得运行权；尚未启动的复测不消耗重试机会。
            self.scoreReview.observe(self.readStatus(claudeProbeStatePath), now: Date().timeIntervalSince1970)
            let busy = self.scanProcess != nil || self.bridge != nil || self.probe != nil
            guard self.scoreReview.shouldRetry(now: Date().timeIntervalSince1970, busy: busy) else {
                self.phase = nil; self.refresh(); return
            }
            self.scoreReview.begin(now: Date().timeIntervalSince1970)
            UserDefaults.standard.set(self.scoreReview.attemptedKey, forKey: "scoreReviewAttemptedKey")
            self.phase = "评分复核"
            self.refresh()
            self.runScript(["--quiet"], claudeScriptPath) { [weak self] _ in
                guard let self else { return }
                self.scoreReview.finish()
                self.phase = nil
                self.refresh()
            }
        }
    }

    // 先采浏览器指纹，再只运行一次完整评分。检测期间保留上次有效分数，
    // 不再把缺少浏览器信号的中间分数写进菜单并触发假告警。
    func fullCheck(_ args: [String] = ["--quiet"], activateBrowser: Bool = false) {
        guard phase == nil, bridge == nil else { return } // 正在检测或报告页还在汇总时别叠加
        guard browserProbeEnabled else {
            phase = "系统检测"
            refresh()
            runScript(args, claudeScriptPath) { [weak self] _ in self?.phase = nil; self?.refresh() }
            return
        }
        phase = "浏览器指纹"
        refresh()
        bridge = BrowserBridge(outPath: browserPath, activateBrowser: activateBrowser, collected: { [weak self] ok in
            guard let self else { return }
            if ok {
                self.phase = "系统检测"
                self.refresh()
                self.runScript(args, claudeScriptPath) { [weak self] _ in
                    guard let self else { return }
                    self.phase = nil
                    self.refresh()
                    self.bridge?.publishReport(self.browserReportPayload())
                }
            } else {
                self.bridge = nil
                self.fallbackWebView(args)
            }
        }, cleanedUp: { [weak self] in
            self?.bridge = nil
        })
        bridge?.start()
    }

    // 真实浏览器没回传时的兜底: 用内置 WKWebView 采一份(拿不到 Client Hints，但总比没有强)
    func fallbackWebView(_ args: [String] = ["--quiet"]) {
        guard probe == nil else { phase = nil; refresh(); return }
        probe = BrowserProbe(outPath: browserPath) { [weak self] in
            guard let self else { return }
            self.probe = nil
            self.phase = "系统检测"
            self.refresh()
            self.runScript(args, claudeScriptPath) { [weak self] _ in
                self?.phase = nil
                self?.refresh()
            }
        }
        probe?.run()
    }

    // 隐藏开关，正常用户不需要知道体检内部分两步。真要关:
    //   defaults write local.cc browserProbe -bool false
    var browserProbeEnabled: Bool {
        UserDefaults.standard.object(forKey: "browserProbe") as? Bool ?? true
    }

    func claudeMenuItem() -> NSMenuItem {
        let c = readStatus(claudeStatusPath)
        let probeState = readStatus(claudeProbeStatePath)
        let score = Int(c["score"] ?? "") ?? -1
        let grade = c["grade"] ?? ""
        let riskLevel = c["risklevel"] ?? grade
        let exitConsistent = c["consistent"] == "1"
        let isSafe = c["safeuse"] == "1" && exitConsistent
        let isWarning = riskLevel == "低风险" || riskLevel == "中风险"
        let dot: String
        switch riskLevel {
        case "安全": dot = "🟢"
        case "低风险": dot = "🟡"
        case "中风险": dot = "🟠"
        case "高风险", "极高风险": dot = "🔴"
        default: dot = score < 0 ? "⚪️" : "🟠"
        }
        let riskColor: NSColor = isSafe ? .labelColor : (isWarning ? .systemOrange : .systemRed)
        // 提分详情在子菜单顶部，标题只报状态，不啰嗦
        let verifying = probeState["state"] == "verifying"
        let reviewLabel = scoreReview.label(now: Date().timeIntervalSince1970)
        let title = score < 0 ? "Claude 环境体检"
            : "Claude 环境 \(dot) \(score) 分 · \(reviewLabel ?? riskLevel)"
        let unfit = score >= 0 && !isSafe
        let alertColor: NSColor = score < 0 ? .labelColor : riskColor

        let sub = NSMenu()
        if score < 0 {
            sub.addItem(disabled("尚未体检"))
        } else {
            if verifying {
                switch reviewLabel {
                case "待复核": sub.addItem(disabled("等待一次自动复测；已有任务结束后继续"))
                case "复核中": sub.addItem(disabled("正在执行一次评分复测，复用已有浏览器数据"))
                default: sub.addItem(colored("复核未完成，请重新体检", .systemOrange))
                }
                let candidate = probeState["candidate_score"] ?? "?"
                let count = probeState["failure_count"] ?? "1"
                let required = probeState["confirm_required"] ?? "2"
                sub.addItem(colored("探测波动：保留上次 \(score) 分", .systemOrange))
                sub.addItem(disabled("候选 \(candidate) 分 · 复核 \(count)/\(required)"))
                if let detail = probeState["detail"], !detail.isEmpty {
                    sub.addItem(disabled(detail))
                }
                sub.addItem(.separator())
            }
            sub.addItem(unfit ? colored(c["verdict"] ?? "", riskColor) : disabled(c["verdict"] ?? ""))

            // 提分清单放最前面，橙色可点，别埋在明细里跟着一起变灰
            let gains = (c["gains"] ?? "").split(separator: "|").map(String.init)
            sub.addItem(.separator())
            if gains.isEmpty {
                sub.addItem(colored("🎉 已满分", .labelColor))
            } else {
                sub.addItem(colored("还能提 \(100 - score) 分", .labelColor))
                let fixableNames = ["系统时区匹配出口", "系统区域匹配出口", "DNS 出口", "代理形态"]
                let browserSettingNames: Set<String> = ["浏览器语言", "Intl 区域设置", "HTTP 语言首标"]
                for g in gains {
                    let f = g.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
                    guard f.count >= 3 else { continue }
                    // 能一键修的项，点它就直接修
                    let canFix = c["fixable"] == "1" && fixableNames.contains(f[0])
                    let mark = canFix ? "⚡" : "＋\(f[1])"
                    let selector = !canFix && browserSettingNames.contains(f[0])
                        ? #selector(openBrowserLanguageSettings) : #selector(runClaudeFix)
                    sub.addItem(colored("   \(mark)  \(f[0])：\(f[2])", .labelColor,
                                        selector))
                }
            }
            // 26 项信号，按六组展示: 分组~标签~权重~得分~值
            var group = ""
            for row in (c["signals"] ?? "").split(separator: ";") {
                let f = row.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
                guard f.count >= 5 else { continue }
                if f[0] != group {
                    group = f[0]
                    sub.addItem(.separator())
                    sub.addItem(disabled("── \(group) ──"))
                }
                let ok = f[2] == f[3]
                let line = "\(ok ? "✓" : "⚠")  \(f[1])：\(f[4])   \(f[3])/\(f[2])"
                sub.addItem(unfit && !ok ? colored(line, .systemRed) : disabled(line))
            }
            sub.addItem(.separator())
            sub.addItem(disabled("出口: \(c["ip"] ?? "?") · \(c["city"] ?? "") · \(c["asn"] ?? "?")"))
            sub.addItem(disabled("IP 情报: \(c["intelsources"] ?? "未采集")"))
            sub.addItem(disabled("IPv6: \(ipv6Summary(c))"))
            sub.addItem(disabled("系统: \(c["os"] ?? "?") · \(c["locale"] ?? "?") · \(c["proxymode"] ?? "?")"))
            sub.addItem(disabled("DNS: \(c["dns"] ?? "?") · claude.ai → \(c["dnsresult"] ?? "?")"))
            sub.addItem(disabled("CLI: \(c["claudever"] ?? "?") · 接口 \(c["base"] ?? "?")"))
            func reach(_ key: String, _ msKey: String) -> String {
                let status = c[key] ?? "未采集"
                if status == "ok", let ms = c[msKey], !ms.isEmpty { return "✓ \(ms)ms" }
                if status == "ok" { return "✓" }
                if status == "timeout" { return "超时" }
                if status == "error" { return "异常" }
                return "未采集"
            }
            sub.addItem(disabled("浏览器访问: 官网 \(reach("branthropic", "branthropicms")) · API \(reach("brapi", "brapims"))"))
            let rtcStatus: String = {
                switch c["brrtcstatus"] ?? "未采集" {
                case "ok": return "完成"
                case "none": return "完成，无公网候选"
                case "timeout": return "超时"
                case "error": return "异常"
                case "unsupported": return "不支持或已禁用"
                default: return "未采集"
                }
            }()
            let rtcElapsed = (c["brrtcms"] ?? "").isEmpty ? "" : " · \(c["brrtcms"]!)ms"
            sub.addItem(disabled("WebRTC 探测: \(rtcStatus) · 候选 \(c["brrtccandidates"] ?? "0") · 公网 \(c["brrtcpublic"] ?? "0")\(rtcElapsed)"))
            let headerState: String
            switch c["brheaders"] ?? "unknown" {
            case "ok": headerState = "✓ 一致"
            case "conflict": headerState = "⚠ 冲突"
            case "partial": headerState = "部分采集"
            default: headerState = "未采集"
            }
            sub.addItem(disabled("浏览器请求头: \(headerState) · Sec-Fetch \(c["brfetch"] ?? "?")"))
            if c["restartpending"] == "1" {
                sub.addItem(colored("浏览器相关项待重启验证", .systemOrange))
            }
            // issues/fixes 两段与顶部提分清单、「手动处理步骤」子菜单重复，
            // 还是弹窗里最长的行 —— 删掉，宽度和高度一起降下来
            sub.addItem(.separator())
            sub.addItem(disabled("体检时间: \(c["time"] ?? "—")"))
        }
        sub.addItem(.separator())
        if c["needsudo"] == "1" {
            sub.addItem(disabled("⚠️ 部分修复需 sudo 授权"))
        }

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if unfit {
            item.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: alertColor,
                .font: NSFont.menuFont(ofSize: 0)
            ])
        }
        item.submenu = sub
        return item
    }

    @objc func runClaudeCheck() { fullCheck(["--quiet", "--refresh-network"], activateBrowser: true) }

    @objc func toggleBrowserProbe() {
        UserDefaults.standard.set(!browserProbeEnabled, forKey: "browserProbe")
        refresh()
    }

    func parsedGains(_ c: [String: String]) -> [[String]] {
        (c["gains"] ?? "").split(separator: "|").compactMap { row in
            let fields = row.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
            return fields.count >= 3 ? fields : nil
        }
    }

    func autoFixableLabels(_ c: [String: String]) -> Set<String> {
        let list = c["fixlist"] ?? ""
        return Set([
            list.contains("时区") ? "系统时区匹配出口" : "",
            list.contains("系统区域") ? "系统区域匹配出口" : "",
            list.contains("DNS") ? "DNS 出口" : "",
            list.contains("PAC") ? "代理形态" : "",
        ].filter { !$0.isEmpty })
    }

    func manualFixRows(_ c: [String: String]) -> [[String]] {
        let automatic = autoFixableLabels(c)
        return parsedGains(c).filter { !automatic.contains($0[0]) }
    }

    func hasBrowserLanguageWork(_ rows: [[String]]) -> Bool {
        let labels: Set<String> = ["浏览器语言", "Intl 区域设置", "HTTP 语言首标"]
        return rows.contains { labels.contains($0[0]) }
    }

    func openBrowserSettings(_ browser: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        switch browser {
        case let value where value.contains("Chrome"):
            p.arguments = ["-a", "Google Chrome", "chrome://settings/languages"]
        case let value where value.contains("Edge"):
            p.arguments = ["-a", "Microsoft Edge", "edge://settings/languages"]
        case let value where value.contains("Firefox"):
            p.arguments = ["-a", "Firefox", "about:preferences#general"]
        default:
            // Safari 跟随 macOS 的每 App/系统语言；未知浏览器也先打开正确的系统入口。
            p.arguments = ["x-apple.systempreferences:com.apple.Localization-Settings.extension"]
        }
        do { try p.run() }
        catch { notify("无法自动打开设置", "请按手动处理步骤进入浏览器语言设置") }
    }

    @objc func openBrowserLanguageSettings() {
        let c = readStatus(claudeStatusPath)
        openBrowserSettings(c["brbrowser"] ?? "")
    }

    func fixPlanLines(_ c: [String: String]) -> [String] {
        let list = c["fixlist"] ?? ""
        var lines: [String] = []
        if list.contains("时区") {
            lines.append("• 时区：\(c["systz"] ?? "?") → \(c["iptz"] ?? "?")")
        }
        if list.contains("系统区域") {
            lines.append("• 系统区域：\(c["locale"] ?? "?") → \(c["fixlocale"] ?? c["country"] ?? "?")（不改显示语言）")
        }
        if list.contains("PAC") {
            lines.append("• 关闭 PAC 自动分流：\(c["proxymode"] ?? "?")")
        }
        if list.contains("DNS") {
            lines.append("• DNS 设置：检查解析后将当前网络服务设为 1.1.1.1（允许代理 fake-IP；代理可能仍接管解析）")
        }
        return lines
    }

    func presentFixResult(exitStatus: Int32) {
        let c = readStatus(claudeStatusPath)
        let results = c["fixresults"] ?? ""
        let errors = c["fixerrors"] ?? ""
        let manual = manualFixRows(c)
        var sections: [String] = []
        if !results.isEmpty {
            sections.append("已完成：\n" + results.components(separatedBy: "；").map { "• " + $0 }.joined(separator: "\n"))
        }
        if !errors.isEmpty {
            sections.append("未完成：\n" + errors.components(separatedBy: "；").map { "• " + $0 }.joined(separator: "\n"))
        } else if exitStatus != 0 {
            sections.append("修复进程异常退出（状态 \(exitStatus)），请重新体检后再试。")
        }
        if c["restartpending"] == "1" {
            sections.append("浏览器相关信号待重启验证：完全退出并重开浏览器，再点“重新体检”。")
        }
        if !manual.isEmpty {
            let lines = manual.map { "• \($0[0])：\($0[2])" }.joined(separator: "\n")
            sections.append("需要手动处理：\n" + lines)
        }
        if sections.isEmpty { sections.append("没有检测到可自动修复的项目。") }

        let alert = NSAlert()
        alert.alertStyle = errors.isEmpty && exitStatus == 0 ? .informational : .warning
        alert.messageText = errors.isEmpty && exitStatus == 0 ? "修复完成" : "部分项目未完成"
        alert.informativeText = sections.joined(separator: "\n\n")
        alert.addButton(withTitle: "知道了")
        if hasBrowserLanguageWork(manual) { alert.addButton(withTitle: "打开浏览器语言设置") }
        let response = alert.runModal()
        if response == .alertSecondButtonReturn { openBrowserSettings(c["brbrowser"] ?? "") }
    }

    // 修复前明确列出自动变更与手动项；确认后逐项执行，某一项失败不回滚其它成功项。
    @objc func runClaudeFix() {
        guard phase == nil else { return }
        let c = readStatus(claudeStatusPath)
        let automatic = fixPlanLines(c)
        let manual = manualFixRows(c)
        let alert = NSAlert()
        alert.alertStyle = automatic.isEmpty ? .informational : .warning
        alert.messageText = automatic.isEmpty ? "这些项目需要手动处理" : "确认一键修复"
        var sections: [String] = []
        if !automatic.isEmpty { sections.append("将自动修改：\n" + automatic.joined(separator: "\n")) }
        if !manual.isEmpty {
            sections.append("需要手动处理：\n" + manual.map { "• \($0[0])：\($0[2])" }.joined(separator: "\n"))
        }
        alert.informativeText = sections.isEmpty ? "当前没有需要修复的项目。" : sections.joined(separator: "\n\n")
        alert.addButton(withTitle: automatic.isEmpty ? "知道了" : "开始修复")
        if !automatic.isEmpty { alert.addButton(withTitle: "取消") }
        else if hasBrowserLanguageWork(manual) { alert.addButton(withTitle: "打开浏览器语言设置") }

        let response = alert.runModal()
        if automatic.isEmpty {
            if response == .alertSecondButtonReturn { openBrowserSettings(c["brbrowser"] ?? "") }
            return
        }
        guard response == .alertFirstButtonReturn else { return }
        phase = "修复中"; refresh()
        runScript(["--fix", "--yes"], claudeScriptPath) { [weak self] status in
            guard let self else { return }
            self.phase = nil
            self.refresh()
            self.presentFixResult(exitStatus: status)
        }
    }

    @objc func runCheck() { runScript(["--check"], isScan: true) }

    @objc func openYinso() {
        NSWorkspace.shared.open(URL(string: "https://www.yinso.com/labs/")!)
    }

    @objc func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}

// 浏览器端信号采集: 用一个隐藏的 WKWebView 跑检测 JS，拿 shell 拿不到的那部分信号
// (WebRTC 泄漏 / Intl locale / 渲染指纹 / 字体 / Emoji)，结果写成 key=value 给 cc-check.sh 读。
//
// 注意: WKWebView 是 Safari 引擎，指纹与用户实际用的 Chrome 不完全一致；能反映的是
// "这台机器 + 这条网络"的环境画像，不是某个浏览器的完整指纹。
//
// WebRTC 是这里最有价值的一项: 它走 UDP，不经过 HTTP 代理，所以能暴露代理没兜住的真实出口。
final class BrowserProbe: NSObject, WKScriptMessageHandler {
    private var webView: WKWebView?
    private var window: NSWindow?
    private var timeout: Timer?
    private var done = false
    private var collected: [String: Any] = [:]
    private let outPath: String
    private let completion: () -> Void

    init(outPath: String, completion: @escaping () -> Void) {
        self.outPath = outPath
        self.completion = completion
        super.init()
    }

    func run() {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "cc")
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), configuration: cfg)
        webView = wv
        // 离屏窗口: WKWebView 不在窗口层级里时，系统会把 setTimeout 节流到几十秒，
        // WebRTC 那段等不到结果。挂进一个屏幕外的 1px 窗口就恢复正常速度。
        let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1, height: 1),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.contentView = wv
        w.alphaValue = 0.01
        w.orderBack(nil)
        window = w
        wv.loadHTMLString(Self.html, baseURL: URL(string: "https://local.probe/"))
        // JS 卡住(STUN 不通等)时兜底，别让菜单一直等
        timeout = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.collected["rtc_timeout"] = "1"
            let rtc = String(describing: self.collected["rtc_status"] ?? "")
            if rtc.isEmpty || rtc == "collecting" { self.collected["rtc_status"] = "timeout" }
            self.finish(self.collected)
        }
    }

    func userContentController(_ c: WKUserContentController, didReceive msg: WKScriptMessage) {
        guard let d = msg.body as? [String: Any] else { return finish(["error": "返回格式异常"]) }
        collected.merge(d) { _, new in new }
        // JS 分两次发: 第一次是同步信号(语言/时区/指纹)，第二次带 WebRTC 结果。
        // 先落盘一次，这样即便 STUN 不通也不会丢掉已拿到的信号。
        if d["phase"] as? String == "final" { finish(collected) } else { write(collected) }
    }

    private func write(_ dict: [String: Any]) {
        var txt = "time=\(Int(Date().timeIntervalSince1970))\n"
        for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
            txt += "\(k)=\(String(describing: v).replacingOccurrences(of: "\n", with: " "))\n"
        }
        try? txt.write(toFile: outPath, atomically: true, encoding: .utf8)
    }

    private func finish(_ dict: [String: Any]) {
        guard !done else { return }
        done = true
        timeout?.invalidate()
        write(dict)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "cc")
        window?.close(); window = nil
        webView = nil
        completion()
    }

    private static let html = """
    <!doctype html><meta charset="utf-8"><body><script>
    (async () => {
      const out = {};
      const send = (phase) => {
        out.phase = phase;
        try { webkit.messageHandlers.cc.postMessage(out); } catch(e){}
      };
      try {
        // ── 浏览器身份画像 ──
        out.source = 'webview';
        out.ua_js = navigator.userAgent || '';
        out.languages = (navigator.languages || []).join(',');
        const ro = Intl.DateTimeFormat().resolvedOptions();
        out.tz = ro.timeZone || '';
        out.locale = ro.locale || '';
        out.tzoffset = String(-new Date().getTimezoneOffset() / 60);
        out.platform = navigator.platform || '';
        out.hw = String(navigator.hardwareConcurrency || '');

        // ── 终端环境指纹: 渲染特征 ──
        try {
          const c = document.createElement('canvas'), x = c.getContext('2d');
          x.textBaseline = 'top'; x.font = '14px Arial';
          x.fillText('Claude环境检测', 2, 2);
          const d = c.toDataURL();
          let h = 0; for (let i = 0; i < d.length; i++) h = (h * 31 + d.charCodeAt(i)) | 0;
          out.canvas = (h >>> 0).toString(16);
        } catch (e) { out.canvas = ''; }
        try {
          const gl = document.createElement('canvas').getContext('webgl');
          const dbg = gl.getExtension('WEBGL_debug_renderer_info');
          out.webgl = gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) || '';
        } catch (e) { out.webgl = ''; }
        // Emoji 风格: 苹果彩色字形与开源字形的绘制宽度不同，可粗判是不是原生 macOS 渲染
        try {
          const c = document.createElement('canvas'), x = c.getContext('2d');
          x.font = '16px sans-serif';
          out.emojiw = String(Math.round(x.measureText('\\u{1F600}').width * 10) / 10);
        } catch (e) { out.emojiw = ''; }

        // ── 字体探测: 装了哪些中文字体(国产终端弱信号) ──
        try {
          const probe = ['PingFang SC','Hiragino Sans GB','Microsoft YaHei','SimSun','Songti SC','STHeiti'];
          const s = document.createElement('span');
          s.style.cssText = 'position:absolute;left:-9999px;font-size:72px';
          s.textContent = 'mmmmmmmmmmlli测试';
          document.body.appendChild(s);
          s.style.fontFamily = 'monospace'; const base = s.offsetWidth;
          out.fonts = probe.filter(f => {
            s.style.fontFamily = "'" + f + "',monospace";
            return s.offsetWidth !== base;
          }).join(',');
          s.remove();
        } catch (e) { out.fonts = ''; }

        send('sync');   // 同步信号先落盘，网络探测或 WebRTC 慢时也不会连累它们

        // ── 浏览器侧 Claude 服务可达性 ──
        // shell curl 和真实浏览器可能走不同的 PAC/扩展代理；这里只判断传输路径能否完成，
        // no-cors 看不到 401/403，不能替代 shell 侧的地区拦截判定。
        const reachOne = async (key, url) => {
          const started = performance.now(), ctl = new AbortController();
          const timer = setTimeout(() => ctl.abort(), 3500);
          try {
            await fetch(url, { mode: 'no-cors', cache: 'no-store', signal: ctl.signal });
            out['reach_' + key] = 'ok';
            out['reach_' + key + '_ms'] = String(Math.round(performance.now() - started));
          } catch (e) {
            out['reach_' + key] = e && e.name === 'AbortError' ? 'timeout' : 'error';
            out['reach_' + key + '_ms'] = '';
          } finally { clearTimeout(timer); }
        };
        // 不探 claude.ai: 它拒绝一切跨站子资源请求(fetch/img)，在任何第三方页面里都恒 error，
        // 与本机链路无关(顶层导航是正常的)。可达性以 shell 侧 curl robots.txt 为准。
        const reachPromise = Promise.all([
          reachOne('anthropic', 'https://www.anthropic.com/'),
          reachOne('api', 'https://api.anthropic.com/')
        ]);

        // ── WebRTC 泄漏: 明确区分无泄漏、超时、异常和不支持 ──
        out.rtc_host = ''; out.rtc_srflx = ''; out.rtc_candidate_count = '0';
        out.rtc_public_count = '0'; out.rtc_supported = '0'; out.rtc_status = 'unsupported';
        if ('RTCPeerConnection' in window) {
          out.rtc_supported = '1'; out.rtc_status = 'collecting';
          const rtcStarted = performance.now();
          try {
            const pc = new RTCPeerConnection({ iceServers: [
              { urls: 'stun:stun.cloudflare.com:3478' },
              { urls: 'stun:stun.l.google.com:19302' }
            ]});
            pc.createDataChannel('probe');
            const hosts = new Set(), srflx = new Set();
            let candidates = 0, completed = false, finishGathering;
            const gathered = new Promise(r => { finishGathering = r; });
            pc.onicecandidate = e => {
              if (!e.candidate) { completed = true; finishGathering(); return; }
              candidates += 1;
              const c = e.candidate.candidate;
              const m = c.match(/([0-9]{1,3}(?:\\.[0-9]{1,3}){3})/);
              if (!m) return;
              if (c.indexOf('typ host') >= 0) hosts.add(m[1]);
              if (c.indexOf('typ srflx') >= 0) srflx.add(m[1]);
            };
            pc.onicegatheringstatechange = () => {
              if (pc.iceGatheringState === 'complete') { completed = true; finishGathering(); }
            };
            await pc.setLocalDescription(await pc.createOffer());
            await Promise.race([gathered, new Promise(r => setTimeout(r, 4500))]);
            out.rtc_host = [...hosts].join(',');
            out.rtc_srflx = [...srflx].join(',');
            out.rtc_candidate_count = String(candidates);
            out.rtc_public_count = String(srflx.size);
            out.rtc_elapsed_ms = String(Math.round(performance.now() - rtcStarted));
            out.rtc_status = srflx.size > 0 ? 'ok' : (completed ? 'none' : 'timeout');
            pc.close();
          } catch (e) {
            out.rtc_status = 'error';
            out.rtc_elapsed_ms = String(Math.round(performance.now() - rtcStarted));
            out.rtc_err = String(e).slice(0, 60);
          }
        }
        await reachPromise;
      } catch (e) {
        out.error = String(e).slice(0, 100);
      }
      send('final');
    })();
    </script></body>
    """
}


// 真实浏览器指纹采集: 起一个只听 127.0.0.1 的极简 HTTP server，用 open 唤起用户的默认浏览器
// 来访问它。WKWebView 是 Safari 引擎，拿不到 Client Hints / Sec-Fetch，也不是用户真正登录
// claude.ai 时用的那个浏览器；走这条路采到的才是 Anthropic 网页端实际看到的指纹。
//
// 安全: 只绑 127.0.0.1、随机端口、URL 带一次性 token、拿到结果或 90 秒超时立即关闭监听。
final class BrowserBridge {
    private var listener: NWListener?
    private var collectionTimeout: Timer?
    private var cleanupTimer: Timer?
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
    private let outPath: String
    private let activateBrowser: Bool
    private let collected: (Bool) -> Void
    private let cleanedUp: () -> Void
    private let ready: ((URL) -> Void)?
    private var collectionDelivered = false
    private var cleaned = false
    private var reportData: Data?

    init(outPath: String, activateBrowser: Bool = false,
         collected: @escaping (Bool) -> Void,
         cleanedUp: @escaping () -> Void, ready: ((URL) -> Void)? = nil) {
        self.outPath = outPath
        self.activateBrowser = activateBrowser
        self.collected = collected
        self.cleanedUp = cleanedUp
        self.ready = ready
    }

    func start() {
        do {
            // 必须显式绑到 127.0.0.1。NWParameters.tcp + on:.any 会监听 0.0.0.0，
            // macOS 15 起这属于「本地网络」访问，未授权时浏览器连不上来，
            // 浏览器组信号会整组掉到中性分；纯 loopback 则豁免该权限。
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            l.stateUpdateHandler = { [weak self] state in
                guard case .ready = state, let self, let port = self.listener?.port else { return }
                let url = "http://127.0.0.1:\(port.rawValue)/c?t=\(self.token)"
                guard let reportURL = URL(string: url) else { return }
                if let ready = self.ready {
                    ready(reportURL)
                } else {
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = self.activateBrowser
                    config.addsToRecentItems = false
                    NSWorkspace.shared.open(reportURL, configuration: config, completionHandler: nil)
                }
            }
            listener = l
            l.start(queue: .main)
            collectionTimeout = Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { [weak self] _ in
                self?.deliverCollection(false)
                self?.cleanup()
            }
        } catch {
            deliverCollection(false)
            cleanup()
        }
    }

    func publishReport(_ payload: [String: Any]) {
        guard !cleaned, JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        reportData = data
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveRequest(connection, buffer: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if self.requestIsComplete(accumulated) {
                self.processRequest(connection, data: accumulated)
            } else if error == nil, !isComplete, accumulated.count < 262144 {
                self.receiveRequest(connection, buffer: accumulated)
            } else {
                connection.cancel()
            }
        }
    }

    private func requestIsComplete(_ data: Data) -> Bool {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator),
              let header = String(data: data[..<range.lowerBound], encoding: .utf8) else { return false }
        let contentLength = header.components(separatedBy: "\r\n").compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        return data.count >= range.upperBound + contentLength
    }

    private func processRequest(_ connection: NWConnection, data: Data) {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator),
              let header = String(data: data[..<range.lowerBound], encoding: .utf8) else {
            respond(connection, 400, "text/plain; charset=utf-8", Data("bad request".utf8)); return
        }
        let lines = header.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? ""
        let parts = requestLine.split(separator: " ").map(String.init)
        guard parts.count >= 2 else {
            respond(connection, 400, "text/plain; charset=utf-8", Data("bad request".utf8)); return
        }
        let method = parts[0], target = parts[1]
        let suppliedToken = URLComponents(string: target)?.queryItems?.first(where: { $0.name == "t" })?.value
        guard suppliedToken == String(token) else {
            respond(connection, 403, "text/plain; charset=utf-8", Data("forbidden".utf8)); return
        }

        if method == "POST", target.hasPrefix("/r?") {
            let bodyData = data.subdata(in: range.upperBound..<data.count)
            let body = String(data: bodyData, encoding: .utf8) ?? ""
            save(headers: lines, body: body)
            respond(connection, 200, "text/plain; charset=utf-8", Data("ok".utf8))
            deliverCollection(true)
            scheduleCleanup()
        } else if method == "GET", target.hasPrefix("/report?") {
            if let reportData {
                respond(connection, 200, "application/json; charset=utf-8", reportData)
            } else {
                respond(connection, 202, "application/json; charset=utf-8", Data("{\"ready\":false}".utf8))
            }
        } else if method == "POST", target.hasPrefix("/close?") {
            respond(connection, 200, "text/plain; charset=utf-8", Data("closed".utf8)) { [weak self] in
                self?.cleanup()
            }
        } else if method == "GET" {
            respond(connection, 200, "text/html; charset=utf-8", Data(Self.page(token: String(token)).utf8))
        } else {
            respond(connection, 404, "text/plain; charset=utf-8", Data("not found".utf8))
        }
    }

    private func respond(_ connection: NWConnection, _ code: Int, _ type: String, _ body: Data,
                         completion: (() -> Void)? = nil) {
        let reason: String
        switch code {
        case 200: reason = "OK"
        case 202: reason = "Accepted"
        case 400: reason = "Bad Request"
        case 403: reason = "Forbidden"
        default: reason = "Not Found"
        }
        var headers = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        headers += "Cache-Control: no-store, max-age=0\r\nPragma: no-cache\r\nReferrer-Policy: no-referrer\r\n"
        headers += "X-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\n"
        if type.hasPrefix("text/html") {
            headers += "Content-Security-Policy: default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self' https://claude.ai https://www.anthropic.com https://api.anthropic.com; img-src 'none'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'\r\n"
        }
        headers += "Connection: close\r\n\r\n"
        connection.send(content: Data(headers.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
            if let completion { DispatchQueue.main.async(execute: completion) }
        })
    }

    private func save(headers: [String], body: String) {
        var output: [String: String] = ["source": "browser"]
        let wanted = ["user-agent": "ua", "accept-language": "accept_lang",
                      "sec-ch-ua": "ch_ua", "sec-ch-ua-platform": "ch_platform",
                      "sec-ch-ua-mobile": "ch_mobile", "sec-fetch-site": "sf_site",
                      "sec-fetch-mode": "sf_mode", "sec-fetch-dest": "sf_dest"]
        for header in headers.dropFirst() {
            guard let index = header.firstIndex(of: ":") else { continue }
            let key = header[..<index].lowercased()
            let value = header[header.index(after: index)...].trimmingCharacters(in: .whitespaces)
            if let mapped = wanted[String(key)] {
                output[mapped] = value.replacingOccurrences(of: "\"", with: "")
            }
        }
        for pair in body.components(separatedBy: "\n") {
            guard let index = pair.firstIndex(of: "=") else { continue }
            output[String(pair[..<index])] = String(pair[pair.index(after: index)...])
        }
        var text = "time=\(Int(Date().timeIntervalSince1970))\n"
        for (key, value) in output.sorted(by: { $0.key < $1.key }) {
            text += "\(key)=\(value.replacingOccurrences(of: "\n", with: " "))\n"
        }
        try? text.write(toFile: outPath, atomically: true, encoding: .utf8)
    }

    private func deliverCollection(_ ok: Bool) {
        guard !collectionDelivered else { return }
        collectionDelivered = true
        collectionTimeout?.invalidate(); collectionTimeout = nil
        collected(ok)
    }

    private func scheduleCleanup() {
        cleanupTimer?.invalidate()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: false) { [weak self] _ in
            self?.cleanup()
        }
    }

    private func cleanup() {
        guard !cleaned else { return }
        cleaned = true
        collectionTimeout?.invalidate(); cleanupTimer?.invalidate()
        listener?.cancel(); listener = nil
        cleanedUp()
    }

    static func page(token: String) -> String {
        return """
        <!doctype html>
        <html lang="zh-CN"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>cc 完整环境体检</title>
        <style>
        :root{color-scheme:light dark;--bg:#f5f6f8;--surface:#fff;--surface2:#f8f9fb;--text:#172033;--muted:#667085;--line:#dfe3ea;--good:#08783e;--goodbg:#eaf8f0;--caution:#806000;--cautionbg:#fff8cf;--warn:#9a5700;--warnbg:#fff4dc;--bad:#b42318;--badbg:#fff0ee;--info:#175cd3;--infobg:#eef4ff;--accent:#315efb}
        @media(prefers-color-scheme:dark){:root{--bg:#0c111b;--surface:#151c28;--surface2:#1b2432;--text:#f4f6fb;--muted:#aab4c4;--line:#2d394b;--good:#72d69b;--goodbg:#123526;--caution:#f5dc74;--cautionbg:#3a3210;--warn:#f6c76d;--warnbg:#3c2c10;--bad:#ff9b91;--badbg:#451d1d;--info:#9cc2ff;--infobg:#172e55;--accent:#7ca4ff}}
        *{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}button{font:inherit}
        main{width:min(1120px,calc(100% - 32px));margin:36px auto 80px}.top{display:flex;align-items:flex-start;justify-content:space-between;gap:24px;margin-bottom:22px}.brand{font-size:13px;font-weight:750;letter-spacing:.08em;color:var(--accent)}h1{margin:5px 0 6px;font-size:clamp(27px,4vw,42px);line-height:1.15;letter-spacing:-.03em}.lead{margin:0;color:var(--muted)}
        .close{border:1px solid var(--line);background:var(--surface);color:var(--text);border-radius:10px;padding:9px 14px;cursor:pointer}.close:hover{border-color:var(--accent)}
        .status{display:flex;align-items:center;gap:10px;margin:18px 0;padding:13px 15px;border:1px solid var(--line);border-radius:12px;background:var(--surface)}.spinner{width:16px;height:16px;border:2px solid var(--line);border-top-color:var(--accent);border-radius:50%;animation:spin .8s linear infinite}@keyframes spin{to{transform:rotate(360deg)}}
        .summary{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px;margin:18px 0}.metric{padding:17px;border:1px solid var(--line);border-radius:14px;background:var(--surface)}.metric b{display:block;font-size:25px;line-height:1.2}.metric span{display:block;margin-top:5px;color:var(--muted);font-size:12px}.metric.good{border-color:var(--good);background:var(--goodbg)}.metric.caution{color:var(--caution);border-color:var(--caution);background:var(--cautionbg)}.metric.warn{border-color:var(--warn);background:var(--warnbg)}.metric.bad{border-color:var(--bad);background:var(--badbg)}
        .verdict{margin:0 0 18px;padding:17px 19px;border-radius:14px;background:var(--surface);border:1px solid var(--line);font-weight:650}
        section{margin-top:16px;border:1px solid var(--line);border-radius:15px;background:var(--surface);overflow:hidden}section h2{margin:0;padding:15px 18px 12px;font-size:17px}section .desc{margin:-8px 18px 12px;color:var(--muted);font-size:13px}.rows{border-top:1px solid var(--line)}.row{display:grid;grid-template-columns:minmax(150px,230px) 1fr;gap:18px;padding:11px 18px;border-top:1px solid var(--line)}.row:first-child{border-top:0}.key{color:var(--muted)}.value{min-width:0;overflow-wrap:anywhere;font-variant-numeric:tabular-nums}.mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:13px}
        .pill{display:inline-flex;align-items:center;border-radius:999px;padding:3px 9px;font-size:12px;font-weight:750}.good{color:var(--good);background:var(--goodbg)}.caution{color:var(--caution);background:var(--cautionbg)}.warn{color:var(--warn);background:var(--warnbg)}.bad{color:var(--bad);background:var(--badbg)}.neutral{color:var(--info);background:var(--infobg)}
        .matrix{display:grid;grid-template-columns:1.15fr auto 2fr;gap:0;border-top:1px solid var(--line)}.matrix>div{padding:11px 16px;border-top:1px solid var(--line)}.matrix>div:nth-child(-n+3){border-top:0}.matrix .detail{color:var(--muted)}
        .signal-table{width:100%;border-collapse:collapse}.signal-table th,.signal-table td{text-align:left;padding:10px 13px;border-top:1px solid var(--line);vertical-align:top}.signal-table th{color:var(--muted);font-size:12px}.signal-table td:last-child,.signal-table th:last-child{text-align:right;white-space:nowrap}.signal-table .miss{color:var(--bad);font-weight:700}.signal-table .full{color:var(--good)}
        ul{margin:0;padding:0 0 0 20px}li+li{margin-top:7px}.note{color:var(--muted);font-size:13px}.footer{margin-top:22px;color:var(--muted);font-size:13px;text-align:center}
        @media(max-width:760px){main{width:min(100% - 20px,1120px);margin-top:20px}.top{display:block}.close{margin-top:14px}.summary{grid-template-columns:repeat(2,minmax(0,1fr))}.row{grid-template-columns:1fr;gap:3px}.matrix{grid-template-columns:1fr}.matrix>div{border-top:0}.matrix>div:nth-child(3n){padding-top:3px;padding-bottom:14px;border-bottom:1px solid var(--line)}.signal-table{font-size:13px}.signal-table th:nth-child(1),.signal-table td:nth-child(1){display:none}}
        @media(prefers-reduced-motion:reduce){.spinner{animation:none}}
        </style></head><body><main>
        <div class="top"><div><div class="brand">CC · 本机隐私检测</div><h1>Claude 完整环境体检</h1><p class="lead">浏览器、系统、出口、DNS 与网络路径的一致性报告</p></div><button id="close" class="close" type="button">关闭页面</button></div>
        <div id="status" class="status"><span class="spinner"></span><span>正在采集浏览器信号…</span></div>
        <div id="content"></div><p class="footer">检测数据只在本机 cc 与当前浏览器标签页之间传递，不上传检测报告。</p>
        </main><script>
        (() => {
          const TOKEN = "\(token)";
          const status = document.getElementById("status"), content = document.getElementById("content");
          const o = {};
          const set = (k,v) => { o[k] = String(v == null ? "" : v).replace(/\\n/g," "); };
          const txt = (v,f="未采集") => v == null || v === "" || v === "?" ? f : String(v);
          const element = (tag, cls, value) => { const e=document.createElement(tag); if(cls)e.className=cls; if(value!=null)e.textContent=String(value); return e; };
          const duration = v => { const n=Number(v); if(!Number.isFinite(n)||n<0)return "—"; return n<1?Math.round(n*1000)+"ms":n.toFixed(2)+"s"; };
          const list = v => txt(v,"").split("|").filter(Boolean);
          const section = (title, description="") => { const s=element("section"); s.append(element("h2","",title)); if(description)s.append(element("p","desc",description)); const rows=element("div","rows"); s.append(rows); content.append(s); return rows; };
          const addRow = (rows,key,value,mono=false) => { const r=element("div","row"); r.append(element("div","key",key),element("div","value"+(mono?" mono":""),txt(value))); rows.append(r); };
          const addListSection = (title, values, empty) => { const rows=section(title); const box=element("div","row"); box.append(element("div","key",title)); const value=element("div","value"); if(values.length){const ul=element("ul"); values.forEach(v=>ul.append(element("li","",v))); value.append(ul);}else value.textContent=empty; box.append(value); rows.append(box); };
          const tone = state => state==="good"?"good":state==="bad"?"bad":state==="warn"?"warn":"neutral";
          const stateLabel = state => state==="good"?"一致":state==="bad"?"冲突":state==="warn"?"需关注":"数据不足";
          const matrix = (host,label,state,detail) => { host.append(element("div","",label)); const b=element("div","pill "+tone(state),stateLabel(state)); host.append(b,element("div","detail",detail)); };
          const splitIPs = v => txt(v,"").split(",").map(x=>x.trim()).filter(Boolean);
          const sameIP = (a,b) => !!a && !!b && splitIPs(a).includes(b);
          const hash = value => { let h=2166136261; for(let i=0;i<value.length;i++){h^=value.charCodeAt(i);h=Math.imul(h,16777619);} return (h>>>0).toString(16).padStart(8,"0"); };
          const browserName = ua => ua.includes("Edg/")?"Microsoft Edge":ua.includes("OPR/")?"Opera":ua.includes("Chrome/")?"Chrome":ua.includes("Safari/")&&!ua.includes("Chrome/")?"Safari":ua.includes("Firefox/")?"Firefox":/MicroMessenger/i.test(ua)?"微信内置浏览器":"未知浏览器";
          const osName = ua => /Windows NT/i.test(ua)?"Windows":/Android/i.test(ua)?"Android":/iPhone|iPad/i.test(ua)?"iOS":/Macintosh|Mac OS/i.test(ua)?"macOS":/Linux/i.test(ua)?"Linux":navigator.platform||"未知";
          const escapeClose = () => { try { navigator.sendBeacon("/close?t="+TOKEN, ""); } catch(e){} };
          window.addEventListener("beforeunload", escapeClose);
          document.getElementById("close").onclick = () => { escapeClose(); window.close(); setTimeout(()=>{status.textContent="报告已完成，可以手动关闭此标签页。";},300); };

          function renderWaiting(){
            content.replaceChildren(); const rows=section("浏览器阶段已完成","正在等待本机系统、出口、DNS 与 Claude 连通性检测。");
            addRow(rows,"浏览器",txt(o.browser_name)); addRow(rows,"平台",txt(o.os_name)+" · "+txt(o.platform));
            addRow(rows,"浏览器时区",txt(o.tz)+" · UTC"+(Number(o.tzoffset)>=0?"+":"")+txt(o.tzoffset));
            addRow(rows,"语言 / Locale",txt(o.languages)+" · "+txt(o.locale));
            addRow(rows,"WebRTC",o.rtc_status==="ok"?txt(o.rtc_srflx):txt(o.rtc_status));
            addRow(rows,"运行容器",txt(o.runtime_flags,"未发现自动化或内嵌容器特征"));
          }

          function parseSignals(raw){
            const rows=[], parts=txt(raw,"").split(";"); let current="";
            parts.forEach(part=>{ if((part.match(/~/g)||[]).length>=4){ if(current)rows.push(current); current=part; } else if(current){ current+=";"+part; } });
            if(current)rows.push(current);
            return rows.map(row=>{const f=row.split("~"); return {group:f[0],label:f[1],weight:Number(f[2]||0),points:Number(f[3]||0),value:f.slice(4).join("~")};});
          }

          function ipv6Origin(c){
            if(c.ipv6status==="none")return "无 IPv6 出口（无泄漏面）";
            if(c.ipv6status==="failed")return "探测未完成，暂无法确认";
            if(c.ipv6status!=="ok")return "未区分来源，请重新体检";
            return c.ipv6origin==="local"?"本机地址，未经代理（直连）":c.ipv6origin==="upstream"?"非本机地址，来自代理节点或上游":"来源未知";
          }
          function routeEvidence(n){
            if(n.probe_epoch && Date.now()/1000-Number(n.probe_epoch)>300)return {state:"unknown",complete:false};
            const ips=[n.cn,n.intl,n.gfw].filter(ip=>ip&&ip!=="?");
            const complete=ips.length===3;
            // 兼容旧版失败快照：三个旧 IP 不能作为本轮成功证据。
            const current=n.probe_complete!==undefined || n.network==="ok";
            if(!current)return {state:"unknown",complete:false};
            const state=new Set(ips).size>1?"0":complete?"1":"unknown";
            return {state,complete};
          }

          function renderReport(report){
            const c=report.claude||{}, n=report.network||{}, b=report.browser||o, q=report.quality||{};
            document.title="cc v"+txt(report.version,"?")+" 完整体检报告";
            const countdownText=element("span","","完整报告已生成，页面将在 5 秒后自动关闭。"), keepOpen=element("button","close","保持打开");
            status.replaceChildren(element("span","pill good","检测完成"),countdownText,keepOpen);
            let remaining=5, closeCancelled=false;
            const closeTimer=setInterval(()=>{
              if(closeCancelled){clearInterval(closeTimer);return;}
              remaining-=1;
              if(remaining<=0){
                clearInterval(closeTimer);escapeClose();window.close();
                setTimeout(()=>{countdownText.textContent="浏览器阻止了自动关闭，请手动关闭此标签页。";keepOpen.remove();},400);
              }else countdownText.textContent="完整报告已生成，页面将在 "+remaining+" 秒后自动关闭。";
            },1000);
            keepOpen.onclick=()=>{closeCancelled=true;clearInterval(closeTimer);countdownText.textContent="已取消自动关闭，可继续查看报告。";keepOpen.remove();};
            content.replaceChildren();
            const routes=routeEvidence(n);
            const routeLabel=routes.state==="1"?"三路一致":routes.state==="0"?"检测到出口分流":"检测未完成";
            const routeClass=routes.state==="1"?"good":routes.state==="0"?"bad":"warn";
            const score=Number(c.score||0), safe=score>=90&&c.grade==="优秀"&&routes.state==="1";
            const riskLevel=txt(c.risklevel||c.grade),riskClass=riskLevel==="安全"?"good":riskLevel==="低风险"?"caution":riskLevel==="中风险"||riskLevel==="待确认"?"warn":"bad";
            const summary=element("div","summary");
            [[score+" / 100","环境得分",riskClass],[riskLevel,"使用风险",riskClass],[txt(c.country),"出口国家",""],[routeLabel,"出口状态",routeClass]].forEach(x=>{const m=element("div","metric "+(x[2]||""));m.append(element("b","",x[0]),element("span","",x[1]));summary.append(m);});
            content.append(summary,element("div","verdict "+(safe?"good":score>=70?"warn":"bad"),txt(c.verdict)));

            const matrixSection=element("section"); matrixSection.append(element("h2","","信号一致性矩阵"),element("p","desc","比单项数量更重要的是出口、系统和浏览器彼此是否自洽。")); const matrixHost=element("div","matrix"); matrixSection.append(matrixHost); content.append(matrixSection);
            matrix(matrixHost,"三路出口",routeClass,routeLabel+(routes.complete?"":"（本轮检测未完整）"));
            const routeRows=section("本轮出口探测","仅代表这些探针的实际路径，不能证明所有应用出口一致。");
            addRow(routeRows,"国内侧",txt(n.cn,"未获取"),true); addRow(routeRows,"国外侧",txt(n.intl,"未获取"),true); addRow(routeRows,"第三路",txt(n.gfw,"未获取"),true);
            addRow(routeRows,"上次完整确认（历史参考）",txt(n.last_success)+" · "+txt(n.last_confirmed_ip));
            matrix(matrixHost,"系统时区 ↔ 出口时区",c.systz&&c.iptz&&c.systz===c.iptz?"good":c.iptz&&c.iptz!=="?"?"bad":"neutral",txt(c.systz)+" ↔ "+txt(c.iptz));
            matrix(matrixHost,"浏览器时区 ↔ 出口时区",b.tz&&c.iptz&&b.tz===c.iptz?"good":b.tz&&c.iptz?"bad":"neutral",txt(b.tz)+" ↔ "+txt(c.iptz));
            matrix(matrixHost,"WebRTC ↔ 权威出口",b.rtc_status==="none"?"good":b.rtc_status==="ok"?(sameIP(b.rtc_srflx,n.gfw||c.ip)?"good":"bad"):"neutral",b.rtc_status==="none"?"无公网候选":txt(b.rtc_srflx)+" ↔ "+txt(n.gfw||c.ip));
            matrix(matrixHost,"IPv6 ↔ IPv4 国家",c.ipv6==="无"?"good":c.ipv6country&&c.country&&c.ipv6country===c.country?"good":c.ipv6country&&c.ipv6country!=="?"?"bad":"neutral",txt(c.ipv6)+" · "+txt(c.ipv6country));
            matrix(matrixHost,"HTTP/JS 浏览器画像",c.brheaders==="ok"?"good":c.brheaders==="conflict"?"bad":"neutral",txt(c.brheaders));
            matrix(matrixHost,"DNS 解析",/^(正常|代理接管)/.test(c.dnsresult||"")?"good":/污染|失败/.test(c.dnsresult||"")?"bad":"warn",txt(c.dnsresult)+" · "+txt(c.dnsanswer));
            matrix(matrixHost,"shell ↔ 浏览器连通性",b.reach_api==="ok"&&c.api&&c.api!=="000"?"good":b.reach_api&&b.reach_api!=="ok"?"bad":"neutral","API shell HTTP "+txt(c.api)+" · 浏览器 "+txt(b.reach_api));
            const changes=Number(c.ipchanges||0); matrix(matrixHost,"出口 IP 稳定性",changes<=1?"good":changes<=5?"warn":"bad","24 小时内确认变化 "+changes+" 次 · "+(changes<=1?"建议继续固定当前出口":"请关闭自动切换并固定单一出口"));

            let rows=section("出口与 IP","真实系统探测，不依赖单一浏览器接口。");
            addRow(rows,"权威出口 IP",n.timezone_ip||n.gfw||c.ip,true); addRow(rows,"国内视角",n.cn,true); addRow(rows,"国外视角",n.intl,true); addRow(rows,"谷歌侧",n.gfw,true);
            addRow(rows,"国家 / 城市",txt(c.countryname)+" · "+txt(c.country)+" · "+txt(c.city)); addRow(rows,"ISP / ASN",txt(c.isp)+" · "+txt(c.asn)); addRow(rows,"IP 类型",c.iptype); addRow(rows,"经纬度",txt(c.latitude)+", "+txt(c.longitude));
            addRow(rows,"多源情报",txt(c.intelsources)+" · "+txt(c.intelcount,"0")+" 个来源"); addRow(rows,"IPv6",txt(c.ipv6)+" · "+txt(c.ipv6country)); addRow(rows,"IPv6 来源",ipv6Origin(c));
            addRow(rows,"Cloudflare",txt(c.cfip)+" · "+txt(c.colo)+" / "+txt(c.cfloc)+" · WARP "+txt(c.cfwarp)); addRow(rows,"代理形态",c.proxymode);

            rows=section("时区、区域与语言"); addRow(rows,"出口 IANA 时区",c.iptz); addRow(rows,"系统时区",c.systz); addRow(rows,"浏览器时区",b.tz); addRow(rows,"UTC 偏移",txt(c.tzoffset)+" · 浏览器 UTC"+(Number(b.tzoffset)>=0?"+":"")+txt(b.tzoffset));
            addRow(rows,"系统区域 / 语言",txt(c.locale)+" · "+txt(c.langs)); addRow(rows,"Intl Locale",b.locale); addRow(rows,"浏览器语言",b.languages); addRow(rows,"语言变体",b.language_variant); addRow(rows,"Emoji 风格",b.emoji_style);

            rows=section("WebRTC 与泄漏面"); addRow(rows,"探测状态",b.rtc_status); addRow(rows,"srflx 公网出口",txt(b.rtc_srflx,"无"),true); addRow(rows,"host 候选",txt(b.rtc_host,"无"),true); addRow(rows,"候选 / 公网候选",txt(b.rtc_candidate_count,"0")+" / "+txt(b.rtc_public_count,"0")); addRow(rows,"耗时 / 错误",txt(b.rtc_elapsed_ms,"—")+"ms · "+txt(b.rtc_err,"无"));

            rows=section("DNS"); addRow(rows,"实际 DNS 服务器",c.dnsservers,true); addRow(rows,"DNS 作用域",c.dns); addRow(rows,"claude.ai 解析",c.dnsanswer,true); addRow(rows,"判定",c.dnsresult);

            rows=section("Claude 连通性"); addRow(rows,"Anthropic API（shell）","HTTP "+txt(c.api)); addRow(rows,"claude.ai（shell）","HTTP "+txt(c.web)); addRow(rows,"anthropic.com（shell）","HTTP "+txt(c.site));
            addRow(rows,"claude.ai（浏览器）",txt(b.reach_claude)+" · "+txt(b.reach_claude_ms,"—")+"ms"); addRow(rows,"anthropic.com（浏览器）",txt(b.reach_anthropic)+" · "+txt(b.reach_anthropic_ms,"—")+"ms"); addRow(rows,"API（浏览器）",txt(b.reach_api)+" · "+txt(b.reach_api_ms,"—")+"ms"); addRow(rows,"Claude Code",txt(c.claudever)+" · "+txt(c.base));

            rows=section("浏览器、设备与运行容器"); addRow(rows,"浏览器 / 系统",txt(b.browser_name)+" · "+txt(b.os_name)+" · "+txt(b.device_type)); addRow(rows,"JavaScript UA",b.ua_js,true); addRow(rows,"HTTP User-Agent",b.ua,true); addRow(rows,"Client Hints",txt(b.uad_platform)+" · "+txt(b.uad_arch)+" · "+txt(b.uad_brands));
            addRow(rows,"运行容器",txt(b.runtime_flags,"未发现自动化或内嵌容器特征")); addRow(rows,"屏幕",txt(b.screen)+" · DPR "+txt(b.pixel_ratio)); addRow(rows,"硬件",txt(b.hardware_concurrency)+" 核 · 内存 "+txt(b.device_memory,"未知")+"GB · 触控点 "+txt(b.max_touch_points,"0"));
            addRow(rows,"隐私 / 存储","Cookie "+txt(b.cookie_enabled)+" · LocalStorage "+txt(b.local_storage)+" · DNT "+txt(b.dnt)); addRow(rows,"插件 / MIME",txt(b.plugins_count,"0")+" / "+txt(b.mime_types_count,"0"));
            addRow(rows,"Network Information",txt(b.connection_type)+" · RTT "+txt(b.connection_rtt,"—")+"ms · 下行 "+txt(b.connection_downlink,"—")+"Mbps · 省流 "+txt(b.connection_save_data));
            addRow(rows,"WebGL Vendor",b.webgl_vendor); addRow(rows,"WebGL Renderer",b.webgl_renderer); addRow(rows,"Canvas Hash",b.canvas,true); addRow(rows,"中文字体",txt(b.fonts,"无")); addRow(rows,"厂商字体",txt(b.fonts_vendor,"无"));

            rows=section("线路质量","最近 24 小时成功率与本次 TCP、TLS、TTFB、总耗时。");
            [["cn","国内"],["intl","国外"],["gfw","谷歌侧"],["google","Google 204"]].forEach(([key,label])=>{const v=q[key]||{};addRow(rows,label,txt(v.successRate,"0")+"% 成功 · 失败 "+txt(v.failures,"0")+" · TCP "+duration(v.connect)+" · TLS "+duration(v.tls)+" · TTFB "+duration(v.ttfb)+" · 总耗时 "+duration(v.total)+" · 抖动 "+duration(v.jitter)+" · HTTP "+txt(v.http));});

            const signals=parseSignals(c.signals); const signalSection=element("section"); signalSection.append(element("h2","","26 项加权评分明细"),element("p","desc","新增浏览器诊断只作为证据展示；安全档位仍由经过测试的 100 分模型决定。")); const table=element("table","signal-table"); const head=element("tr");["分组","检测项","证据","得分"].forEach(v=>head.append(element("th","",v))); const thead=element("thead");thead.append(head);const tbody=element("tbody");signals.forEach(s=>{const tr=element("tr");tr.append(element("td","",s.group),element("td","",s.label),element("td","",s.value),element("td",s.points===s.weight?"full":"miss",s.points+" / "+s.weight));tbody.append(tr);});table.append(thead,tbody);signalSection.append(table);content.append(signalSection);

            addListSection("发现的问题",list(c.issues),"未发现明确的环境矛盾信号"); addListSection("修复建议",list(c.fixes),"当前没有修复建议");
            if(c.gains){const grow=section("提分清单");list(c.gains).forEach(item=>{const f=item.split("~");addRow(grow,f[0]+"（+"+txt(f[1],"0")+"）",f.slice(2).join("~"));});}
            rows=section("支付与账号地区（人工核对）","本工具不读取账号或付款资料，因此不会伪装成已自动检测。"); addRow(rows,"账号注册地区","请确认与长期出口国家一致"); addRow(rows,"账单国家","请确认与账号及出口一致"); addRow(rows,"支付卡发行国","请人工确认，不纳入自动评分");
            const note=element("p","footer","报告生成于 "+txt(report.generatedAt)+" · cc v"+txt(report.version)); content.append(note);
            fetch("/close?t="+TOKEN,{method:"POST",body:"",keepalive:true}).catch(()=>{});
          }

          async function pollReport(){
            for(let i=0;i<200;i++){
              try{const r=await fetch("/report?t="+TOKEN,{cache:"no-store"});if(r.status===200){renderReport(await r.json());return;}}catch(e){}
              await new Promise(resolve=>setTimeout(resolve,750));
            }
            status.replaceChildren(element("span","pill bad","超时"),element("span","","系统检测没有在预期时间内完成，请从菜单栏重新体检。"));
          }

          async function collect(){
            try{
              const ua=navigator.userAgent||"", lower=ua.toLowerCase(), ro=Intl.DateTimeFormat().resolvedOptions();
              set("ua_js",ua);set("browser_name",browserName(ua));set("os_name",osName(ua));set("device_type",/iPhone/i.test(ua)?"iPhone":/iPad/i.test(ua)?"iPad":/Android/i.test(ua)?"Android 设备":/Mac/i.test(ua)?"Mac":/Windows/i.test(ua)?"Windows PC":"未知设备");
              set("languages",(navigator.languages||[navigator.language]).filter(Boolean).join(","));set("language_variant",/zh-(tw|hk|mo)|zh-hant/i.test(o.languages)?"繁体中文":/zh-cn|zh-sg|zh-hans|(^|,)zh(,|$)/i.test(o.languages)?"简体中文":"非中文或未识别");
              set("tz",ro.timeZone);set("locale",ro.locale);set("calendar",ro.calendar);set("numbering_system",ro.numberingSystem);set("hour_cycle",ro.hourCycle);set("tzoffset",-new Date().getTimezoneOffset()/60);
              set("platform",navigator.platform);set("vendor",navigator.vendor);set("hardware_concurrency",navigator.hardwareConcurrency);set("device_memory",navigator.deviceMemory||"");set("max_touch_points",navigator.maxTouchPoints||0);
              set("screen",screen.width+"×"+screen.height+" / 可用 "+screen.availWidth+"×"+screen.availHeight+" / "+screen.colorDepth+"bit");set("pixel_ratio",window.devicePixelRatio||1);
              set("cookie_enabled",navigator.cookieEnabled?"可用":"禁用");set("dnt",navigator.doNotTrack||window.doNotTrack||"未设置");set("global_privacy_control",navigator.globalPrivacyControl===true?"启用":"未启用/不支持");set("plugins_count",navigator.plugins?navigator.plugins.length:0);set("mime_types_count",navigator.mimeTypes?navigator.mimeTypes.length:0);
              try{localStorage.setItem("__cc_probe","1");localStorage.removeItem("__cc_probe");set("local_storage","可用");}catch(e){set("local_storage","不可用");}
              const conn=navigator.connection||navigator.mozConnection||navigator.webkitConnection||{};set("connection_type",conn.effectiveType||conn.type||"浏览器不提供");set("connection_rtt",conn.rtt||"");set("connection_downlink",conn.downlink||"");set("connection_save_data",conn.saveData?"开启":"关闭/不支持");
              const flags=[];if(navigator.webdriver)flags.push("navigator.webdriver");if(/HeadlessChrome|PhantomJS/i.test(ua))flags.push("Headless");if(window.top!==window.self)flags.push("iframe");if(lower.includes("; wv)")||lower.includes(" webview")||(lower.includes("version/")&&lower.includes(" chrome/")))flags.push("WebView");if(/MicroMessenger|Weibo/i.test(ua)||ua.includes("QQ/"))flags.push("内嵌浏览器");set("runtime_flags",flags.join(", "));
              set("emoji_style",/iPhone|iPad|Mac OS/i.test(ua)?"Apple Emoji":/Android|HarmonyOS/i.test(ua)?"Android / 厂商 Emoji":/Windows/i.test(ua)?"Windows Emoji":"未知");
              set("feature_webgpu","gpu" in navigator?"支持":"不支持");set("feature_wasm",typeof WebAssembly!=="undefined"?"支持":"不支持");set("feature_service_worker","serviceWorker" in navigator?"支持":"不支持");set("feature_webcrypto",window.crypto&&crypto.subtle?"支持":"不支持");
              if(navigator.userAgentData){set("uad_mobile",navigator.userAgentData.mobile);set("uad_platform",navigator.userAgentData.platform);try{const h=await navigator.userAgentData.getHighEntropyValues(["platformVersion","architecture","fullVersionList"]);set("uad_platform_version",h.platformVersion);set("uad_arch",h.architecture);set("uad_brands",(h.fullVersionList||[]).map(x=>x.brand+" "+x.version).join("; "));}catch(e){}}
              try{const c=document.createElement("canvas");c.width=280;c.height=60;const x=c.getContext("2d");x.fillStyle="#f60";x.fillRect(8,8,80,28);x.fillStyle="#069";x.font="16px Arial";x.fillText("cc 环境检测 🧭",12,27);set("canvas",hash(c.toDataURL()));}catch(e){}
              try{const c=document.createElement("canvas"),gl=c.getContext("webgl")||c.getContext("experimental-webgl"),dbg=gl&&gl.getExtension("WEBGL_debug_renderer_info");if(gl){set("webgl_vendor",dbg?gl.getParameter(dbg.UNMASKED_VENDOR_WEBGL):gl.getParameter(gl.VENDOR));set("webgl_renderer",dbg?gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL):gl.getParameter(gl.RENDERER));set("webgl",o.webgl_vendor+" · "+o.webgl_renderer);}}catch(e){}
              try{const probe=["PingFang SC","PingFang TC","Hiragino Sans GB","Microsoft YaHei","Microsoft JhengHei","SimSun","SimHei","MingLiU","Songti SC","STHeiti","Noto Sans CJK SC","Noto Sans CJK TC","Source Han Sans SC","MiSans","HarmonyOS Sans SC","OPPO Sans","vivo Sans"];const sp=document.createElement("span");sp.style.cssText="position:absolute;left:-9999px;font-size:72px";sp.textContent="mmmmmmmmmmlli测试";document.body.appendChild(sp);sp.style.fontFamily="monospace";const base=sp.offsetWidth;const found=probe.filter(f=>{sp.style.fontFamily="'"+f+"',monospace";return sp.offsetWidth!==base;});sp.remove();set("fonts",found.join(","));set("fonts_sc",found.filter(f=>/SC|YaHei|SimSun|SimHei|Songti|STHeiti|MiSans|HarmonyOS|OPPO|vivo|Hiragino/i.test(f)).join(","));set("fonts_tc",found.filter(f=>/TC|JhengHei|MingLiU|PingFang TC/i.test(f)).join(","));set("fonts_vendor",found.filter(f=>/MiSans|HarmonyOS|OPPO|vivo/i.test(f)).join(","));}catch(e){}
              const reachOne=async(key,url)=>{const started=performance.now(),ctl=new AbortController(),timer=setTimeout(()=>ctl.abort(),3500);try{await fetch(url,{mode:"no-cors",cache:"no-store",signal:ctl.signal});set("reach_"+key,"ok");set("reach_"+key+"_ms",Math.round(performance.now()-started));}catch(e){set("reach_"+key,e&&e.name==="AbortError"?"timeout":"error");set("reach_"+key+"_ms","");}finally{clearTimeout(timer);}};
              const reachPromise=Promise.all([reachOne("anthropic","https://www.anthropic.com/"),reachOne("api","https://api.anthropic.com/")]);
              set("rtc_host","");set("rtc_srflx","");set("rtc_candidate_count",0);set("rtc_public_count",0);set("rtc_supported",0);set("rtc_status","unsupported");
              if("RTCPeerConnection" in window){set("rtc_supported",1);set("rtc_status","collecting");const started=performance.now();try{const pc=new RTCPeerConnection({iceServers:[{urls:"stun:stun.cloudflare.com:3478"},{urls:"stun:stun.l.google.com:19302"}]});pc.createDataChannel("p");const hosts=new Set(),srflx=new Set();let candidates=0,completed=false,finish;const gathered=new Promise(r=>{finish=r;});pc.onicecandidate=e=>{if(!e.candidate){completed=true;finish();return;}candidates++;const c=e.candidate.candidate,m=c.match(/([0-9]{1,3}(?:\\.[0-9]{1,3}){3})/);if(!m)return;if(c.includes("typ host"))hosts.add(m[1]);if(c.includes("typ srflx"))srflx.add(m[1]);};pc.onicegatheringstatechange=()=>{if(pc.iceGatheringState==="complete"){completed=true;finish();}};await pc.setLocalDescription(await pc.createOffer());await Promise.race([gathered,new Promise(r=>setTimeout(r,4500))]);set("rtc_host",[...hosts].join(","));set("rtc_srflx",[...srflx].join(","));set("rtc_candidate_count",candidates);set("rtc_public_count",srflx.size);set("rtc_elapsed_ms",Math.round(performance.now()-started));set("rtc_status",srflx.size>0?"ok":completed?"none":"timeout");pc.close();}catch(e){set("rtc_status","error");set("rtc_elapsed_ms",Math.round(performance.now()-started));set("rtc_err",String(e).slice(0,80));}}
              await reachPromise;
              const body=Object.keys(o).map(k=>k+"="+o[k]).join("\\n");
              const response=await fetch("/r?t="+TOKEN,{method:"POST",headers:{"Content-Type":"text/plain;charset=UTF-8"},body,cache:"no-store"});if(!response.ok)throw new Error("HTTP "+response.status);
              status.replaceChildren(element("span","spinner"),element("span","","浏览器信号已完成，正在汇总系统、出口、DNS与评分结果…"));renderWaiting();await pollReport();
            }catch(e){status.replaceChildren(element("span","pill bad","采集失败"),element("span","",String(e)));}
          }
          collect();
        })();
        </script></body></html>
        """
    }
}


let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // 不在 Dock 显示
let delegate = AppDelegate()
app.delegate = delegate
app.run()
