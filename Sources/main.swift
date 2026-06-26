// NotifBark —— 菜单栏小程序：把指定 app 的 macOS 通知转发到 Bark。
// 自包含：自己读通知库(copy 方案,只读零写入)、过滤、推 Bark；菜单栏可视开关。
// 单一用途：只访问通知库这一个文件，无法被指使读别的文件。
//
// 配置在运行时从 ~/.notif2bark/config.json 读取（不含任何密钥在源码里）。
import AppKit
import Foundation
import SQLite3

let HOME = FileManager.default.homeDirectoryForCurrentUser.path
let DB_BASE = HOME + "/Library/Group Containers/group.com.apple.usernoted/db2/db"
let CONFIG_PATH = HOME + "/.notif2bark/config.json"
let LOG_PATH = HOME + "/.notif2bark/notifbark.log"

// ===== 配置 =====
struct Config {
    var barkURL: String
    var whitelist: Set<String>
    var poll: TimeInterval
}

// 读配置；缺失则写一份模板并返回 nil（界面会提示去填）。
func loadConfig() -> Config? {
    let fm = FileManager.default
    guard let data = fm.contents(atPath: CONFIG_PATH),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let url = obj["barkUrl"] as? String,
          url.hasPrefix("http"), !url.contains("YOUR_KEY")
    else {
        if !fm.fileExists(atPath: CONFIG_PATH) {
            let template = """
            {
              "barkUrl": "https://api.day.app/YOUR_KEY",
              "whitelist": ["com.anthropic.claudefordesktop"],
              "pollSeconds": 3
            }
            """
            try? fm.createDirectory(atPath: HOME + "/.notif2bark",
                                    withIntermediateDirectories: true)
            try? template.write(toFile: CONFIG_PATH, atomically: true, encoding: .utf8)
        }
        return nil
    }
    let wl = Set((obj["whitelist"] as? [String]) ?? [])
    let poll = (obj["pollSeconds"] as? Double) ?? 3.0
    return Config(barkURL: url, whitelist: wl, poll: poll)
}

enum Status { case forwarding, paused, noPermission, noConfig }

func appLog(_ s: String) {
    let line = isoTime() + "  " + s + "\n"
    guard let d = line.data(using: .utf8) else { return }
    if let fh = FileHandle(forWritingAtPath: LOG_PATH) {
        fh.seekToEndOfFile(); fh.write(d); fh.closeFile()
    } else {
        try? line.write(toFile: LOG_PATH, atomically: true, encoding: .utf8)
    }
}
func isoTime() -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f.string(from: Date())
}
func shortTime() -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: Date())
}

// ===== 读通知库(copy 方案) =====
struct ReaderError: Error { let noPermission: Bool; let msg: String }

func readNew(after lastId: Int64) throws -> [(Int64, Data)] {
    let fm = FileManager.default
    let stamp = Int(Date().timeIntervalSince1970 * 1000) % 100000
    let tmpDir = NSTemporaryDirectory() + "notifbark_\(getpid())_\(stamp)"
    try? fm.removeItem(atPath: tmpDir)
    do { try fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true) }
    catch { throw ReaderError(noPermission: false, msg: "mktemp: \(error)") }
    defer { try? fm.removeItem(atPath: tmpDir) }

    let tmpDB = tmpDir + "/db"
    do { try fm.copyItem(atPath: DB_BASE, toPath: tmpDB) }
    catch {
        let ns = error as NSError
        let perm = ns.code == 513 || (ns.underlyingErrors.first as NSError?)?.code == 1
            || "\(error)".contains("permitted")
        throw ReaderError(noPermission: perm, msg: "copy db: \(error)")
    }
    if fm.fileExists(atPath: DB_BASE + "-wal") {
        try? fm.copyItem(atPath: DB_BASE + "-wal", toPath: tmpDB + "-wal")
    }

    var db: OpaquePointer?
    guard sqlite3_open_v2(tmpDB, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
        let m = String(cString: sqlite3_errmsg(db)); sqlite3_close(db)
        throw ReaderError(noPermission: false, msg: "open copy: \(m)")
    }
    defer { sqlite3_close(db) }

    var stmt: OpaquePointer?
    let sql = "SELECT rec_id, data FROM record WHERE rec_id > ? ORDER BY rec_id"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        throw ReaderError(noPermission: false, msg: "prepare: \(String(cString: sqlite3_errmsg(db)))")
    }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_int64(stmt, 1, lastId)

    var rows: [(Int64, Data)] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        let rid = sqlite3_column_int64(stmt, 0)
        var data = Data()
        if let blob = sqlite3_column_blob(stmt, 1) {
            let n = Int(sqlite3_column_bytes(stmt, 1))
            data = Data(bytes: blob, count: n)
        }
        rows.append((rid, data))
    }
    return rows
}

func decode(_ blob: Data) -> (String, String, String, String)? {
    guard !blob.isEmpty,
          let pl = try? PropertyListSerialization.propertyList(from: blob, options: [], format: nil) as? [String: Any]
    else { return nil }
    let bundle = pl["app"] as? String ?? ""
    let req = pl["req"] as? [String: Any] ?? [:]
    let title = req["titl"] as? String ?? ""
    let sub = req["subt"] as? String ?? ""
    let body = req["body"] as? String ?? ""
    return (bundle, title, sub, body)
}

func pushBark(_ barkURL: String, title: String, body: String) {
    func enc(_ s: String) -> String {
        var cs = CharacterSet.alphanumerics; cs.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: cs) ?? ""
    }
    guard let url = URL(string: barkURL) else { return }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    let payload = "title=\(enc(title))&body=\(enc(body))&group=NotifBark&isArchive=1"
    req.httpBody = payload.data(using: .utf8)
    URLSession.shared.dataTask(with: req).resume()
}

// ===== 转发器 =====
final class Forwarder {
    private(set) var status: Status = .paused
    private(set) var lastForward = "(暂无)"
    var onUpdate: (() -> Void)?
    private var timer: Timer?
    private let defaults = UserDefaults.standard
    var config: Config?

    var enabled: Bool {
        get { defaults.object(forKey: "enabled") == nil ? true : defaults.bool(forKey: "enabled") }
        set { defaults.set(newValue, forKey: "enabled"); tick() }
    }
    private var lastId: Int64 {
        get { Int64(defaults.integer(forKey: "lastRecId")) }
        set { defaults.set(Int(newValue), forKey: "lastRecId") }
    }

    func start() {
        let poll = config?.poll ?? 3.0
        timer = Timer.scheduledTimer(withTimeInterval: poll, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 0.8
        tick()
    }

    private func set(_ s: Status) { status = s; onUpdate?() }

    private func tick() {
        guard let cfg = config else { set(.noConfig); return }
        guard enabled else { set(.paused); return }
        do {
            var lid = lastId
            if lid == 0 {                       // 首启基线，不补发历史
                let rows = try readNew(after: 0)
                lid = rows.map { $0.0 }.max() ?? 0
                lastId = lid
                appLog("初始化基线 rec_id=\(lid)")
                set(.forwarding); return
            }
            let rows = try readNew(after: lid)
            for (rid, blob) in rows {
                if rid > lid { lid = rid }
                guard let (bundle, title, sub, body) = decode(blob) else { continue }
                if !cfg.whitelist.isEmpty && !cfg.whitelist.contains(bundle) { continue }
                let t = title.isEmpty ? bundle : title
                let b = sub.isEmpty ? body : (sub + " " + body)
                pushBark(cfg.barkURL, title: t, body: b)
                lastForward = "\(shortTime())  \(t)"
                appLog("已转发 rec=\(rid) [\(bundle)] \(t) | \(b)")
            }
            lastId = lid
            set(.forwarding)
        } catch let e as ReaderError {
            if e.noPermission { set(.noPermission) }
            else { set(.forwarding); appLog("读取出错: \(e.msg)") }
        } catch {
            appLog("未知错误: \(error)")
        }
    }
}

// ===== 菜单栏 UI =====
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let fwd = Forwarder()
    var statusLine: NSMenuItem!
    var lastLine: NSMenuItem!
    var toggleItem: NSMenuItem!

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        fwd.config = loadConfig()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        statusLine = NSMenuItem(title: "状态：…", action: nil, keyEquivalent: ""); statusLine.isEnabled = false
        lastLine = NSMenuItem(title: "上次转发：(暂无)", action: nil, keyEquivalent: ""); lastLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(lastLine)
        menu.addItem(.separator())
        toggleItem = NSMenuItem(title: "暂停转发", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        let test = NSMenuItem(title: "发送测试推送", action: #selector(sendTest), keyEquivalent: ""); test.target = self
        menu.addItem(test)
        menu.addItem(.separator())
        let fda = NSMenuItem(title: "打开「完全磁盘访问」设置…", action: #selector(openFDA), keyEquivalent: ""); fda.target = self
        menu.addItem(fda)
        let cfgItem = NSMenuItem(title: "打开配置文件", action: #selector(openConfig), keyEquivalent: ""); cfgItem.target = self
        menu.addItem(cfgItem)
        let logItem = NSMenuItem(title: "打开日志", action: #selector(openLog), keyEquivalent: ""); logItem.target = self
        menu.addItem(logItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 NotifBark", action: #selector(quit), keyEquivalent: "q"); quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu

        fwd.onUpdate = { [weak self] in DispatchQueue.main.async { self?.refresh() } }
        fwd.start()
        refresh()
    }

    func refresh() {
        let (sym, txt): (String, String)
        switch fwd.status {
        case .forwarding:   (sym, txt) = ("bell.fill", "状态：● 转发中")
        case .paused:       (sym, txt) = ("bell.slash", "状态：○ 已暂停")
        case .noPermission: (sym, txt) = ("exclamationmark.triangle.fill", "状态：⚠️ 无磁盘权限，点下方按钮去授权")
        case .noConfig:     (sym, txt) = ("gearshape.fill", "状态：⚠️ 未配置 Bark，请打开配置文件填写")
        }
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: sym, accessibilityDescription: "NotifBark")
            btn.image?.isTemplate = true
        }
        statusLine.title = txt
        lastLine.title = "上次转发：\(fwd.lastForward)"
        toggleItem.title = fwd.enabled ? "暂停转发" : "启用转发"
    }

    @objc func toggle() { fwd.enabled.toggle(); refresh() }
    @objc func sendTest() {
        if let u = fwd.config?.barkURL { pushBark(u, title: "NotifBark 自测", body: "菜单栏发出的测试推送 ✅") }
    }
    @objc func openFDA() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(u)
        }
    }
    @objc func openConfig() { NSWorkspace.shared.open(URL(fileURLWithPath: CONFIG_PATH)) }
    @objc func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: LOG_PATH)) }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
