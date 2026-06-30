import SwiftUI
import AppKit
import SQLite3
import Foundation

// Pulsing dot to indicate active model inference
struct PulsingDot: View {
    @State private var animate = false
    var color: Color
    
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .scaleEffect(animate ? 1.4 : 1.0)
            .opacity(animate ? 0.4 : 1.0)
            .onAppear {
                withAnimation(Animation.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    animate = true
                }
            }
    }
}

// State container to manage SQLite queries and API polling
class MonitorState: ObservableObject {
    @Published var isOllamaOnline = false
    @Published var activeModel: String? = nil
    @Published var localActiveModel: String? = nil
    @Published var lastProxyActiveModel: String? = nil
    
    // Local Metrics (Fallback)
    @Published var sessionTokens = 0
    @Published var sessionTime: Double = 0.0
    @Published var sessionRequestCount = 0
    @Published var weeklyTokens = 0
    @Published var weeklyTime: Double = 0.0
    @Published var weeklyRequestCount = 0
    
    // Official Cloud Metrics (from Scraper)
    @Published var hasCloudData = false
    @Published var cloudSessionUsedPercent = 0.0
    @Published var cloudSessionResetText = ""
    @Published var cloudWeeklyUsedPercent = 0.0
    @Published var cloudWeeklyResetText = ""
    @Published var cloudBalance = 0.0
    @Published var cloudSessionDetails: [(name: String, count: Int)] = []
    @Published var cloudWeeklyDetails: [(name: String, count: Int)] = []
    @Published var sessionCookie = ""
    
    // Menu Bar Settings
    @Published var showMenuBarPercent = UserDefaults.standard.object(forKey: "showMenuBarPercent") == nil ? true : UserDefaults.standard.bool(forKey: "showMenuBarPercent")
    @Published var menuBarPercentMode = UserDefaults.standard.integer(forKey: "menuBarPercentMode") // 0 = Remaining, 1 = Used
    
    // User Settings (Local limits)
    @Published var limitType = UserDefaults.standard.integer(forKey: "limitType") // 0 = Time, 1 = Tokens
    @Published var sessionLimitTime = UserDefaults.standard.double(forKey: "sessionLimitTime") == 0 ? 30.0 : UserDefaults.standard.double(forKey: "sessionLimitTime") // in minutes
    @Published var sessionLimitTokens = UserDefaults.standard.integer(forKey: "sessionLimitTokens") == 0 ? 50000 : UserDefaults.standard.integer(forKey: "sessionLimitTokens")
    @Published var weeklyLimitTime = UserDefaults.standard.double(forKey: "weeklyLimitTime") == 0 ? 300.0 : UserDefaults.standard.double(forKey: "weeklyLimitTime") // in minutes (5 hours)
    @Published var weeklyLimitTokens = UserDefaults.standard.integer(forKey: "weeklyLimitTokens") == 0 ? 500000 : MapSettingsToken()
    
    static func MapSettingsToken() -> Int {
        return UserDefaults.standard.integer(forKey: "weeklyLimitTokens") == 0 ? 500000 : UserDefaults.standard.integer(forKey: "weeklyLimitTokens")
    }
    
    func parseModelDetails(_ jsonStr: String) -> [(name: String, count: Int)] {
        guard let data = jsonStr.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Int] else {
            return []
        }
        return dict.map { (name: $0.key, count: $0.value) }
                   .sorted { $0.count > $1.count }
    }
    
    private var cachedAppIcon: NSImage?
    
    func getAppIcon() -> NSImage {
        if let cached = cachedAppIcon {
            return cached
        }
        
        let fm = FileManager.default
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let pathInExeDir = exeDir.appendingPathComponent("icon.svg").path
        let pathInCwd = "icon.svg"
        
        let path: String
        if fm.fileExists(atPath: pathInExeDir) {
            path = pathInExeDir
        } else if fm.fileExists(atPath: pathInCwd) {
            path = pathInCwd
        } else {
            path = "/Users/goksal/Projects/ollama-usage-monitor/icon.svg"
        }
        
        let img: NSImage
        if let loaded = NSImage(contentsOfFile: path) {
            loaded.size = NSSize(width: 16, height: 16)
            loaded.isTemplate = true
            img = loaded
        } else {
            let fallback = NSImage(systemSymbolName: "brain.fill", accessibilityDescription: "Ollama Monitor") ?? NSImage()
            fallback.size = NSSize(width: 16, height: 16)
            img = fallback
        }
        
        cachedAppIcon = img
        return img
    }
    
    @Published var showSettings = false
    
    var onUpdate: ((String, NSImage?) -> Void)?
    
    var dbPath: String {
        let currentDir = FileManager.default.currentDirectoryPath
        return "\(currentDir)/ollama_metrics.db"
    }
    
    private var timer: Timer?
    
    init() {
        setbuf(stdout, nil)
        setbuf(stderr, nil)
        
        if UserDefaults.standard.object(forKey: "limitType") == nil {
            UserDefaults.standard.set(0, forKey: "limitType")
            UserDefaults.standard.set(30.0, forKey: "sessionLimitTime")
            UserDefaults.standard.set(50000, forKey: "sessionLimitTokens")
            UserDefaults.standard.set(300.0, forKey: "weeklyLimitTime")
            UserDefaults.standard.set(500000, forKey: "weeklyLimitTokens")
        }
        
        update()
        startTimer()
    }
    
    func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.update()
        }
    }
    
    func update() {
        checkOllamaStatus()
        queryDatabase()
        
        DispatchQueue.main.async {
            // Determine active model: proxy model (local or cloud) overrides local VRAM model if it is active
            if let proxyModel = self.lastProxyActiveModel {
                self.activeModel = proxyModel
            } else {
                self.activeModel = self.localActiveModel
            }
            self.updateMenuBar()
        }
    }
    
    func checkOllamaStatus() {
        guard let url = URL(string: "http://localhost:11434/api/ps") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 1.0
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if error != nil {
                    self.isOllamaOnline = false
                    self.localActiveModel = nil
                    return
                }
                self.isOllamaOnline = true
                
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let models = json["models"] as? [[String: Any]],
                   let firstModel = models.first,
                   let name = firstModel["name"] as? String {
                    self.localActiveModel = name
                } else {
                    self.localActiveModel = nil
                }
            }
        }.resume()
    }
    
    func queryDatabase() {
        var db: OpaquePointer?
        let path = dbPath
        
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            print("[Swift DEBUG] Failed to open DB at \(path)")
            return
        }
        defer {
            sqlite3_close(db)
        }
        
        // Query Cookie Setting
        if let cookie = getSetting(db: db, key: "session_cookie") {
            DispatchQueue.main.async {
                self.sessionCookie = cookie
            }
        }
        
        // Query Cloud Usage
        var cloudQuery = "SELECT session_used_percent, session_reset_text, weekly_used_percent, weekly_reset_text, balance_remaining, session_details_json, weekly_details_json FROM cloud_usage ORDER BY id DESC LIMIT 1;"
        var cloudStmt: OpaquePointer?
        var hasCloud = false
        
        if sqlite3_prepare_v2(db, cloudQuery, -1, &cloudStmt, nil) != SQLITE_OK {
            // Fallback for older schema if migration hasn't run yet
            cloudQuery = "SELECT session_used_percent, session_reset_text, weekly_used_percent, weekly_reset_text, balance_remaining FROM cloud_usage ORDER BY id DESC LIMIT 1;"
            _ = sqlite3_prepare_v2(db, cloudQuery, -1, &cloudStmt, nil)
        }
        
        if let stmt = cloudStmt, sqlite3_step(stmt) == SQLITE_ROW {
            let sPct = sqlite3_column_double(stmt, 0)
            let sReset = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let wPct = sqlite3_column_double(stmt, 2)
            let wReset = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let bal = sqlite3_column_double(stmt, 4)
            
            var sDetails = "{}"
            var wDetails = "{}"
            if sqlite3_column_count(stmt) >= 7 {
                sDetails = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "{}"
                wDetails = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? "{}"
            }
            
            hasCloud = true
            let sParsed = self.parseModelDetails(sDetails)
            let wParsed = self.parseModelDetails(wDetails)
            print("[Swift DEBUG] Read cloud_usage successfully: session=\(sPct)%, weekly=\(wPct)%, bal=\(bal), sDetails=\(sDetails), wDetails=\(wDetails)")
            
            DispatchQueue.main.async {
                self.cloudSessionUsedPercent = sPct
                self.cloudSessionResetText = sReset
                self.cloudWeeklyUsedPercent = wPct
                self.cloudWeeklyResetText = wReset
                self.cloudBalance = bal
                self.cloudSessionDetails = sParsed
                self.cloudWeeklyDetails = wParsed
                self.hasCloudData = true
            }
        } else {
            print("[Swift DEBUG] No rows returned or failed step on cloudQuery")
        }
        sqlite3_finalize(cloudStmt)
        
        if !hasCloud {
            print("[Swift DEBUG] hasCloud is false, setting hasCloudData = false")
            DispatchQueue.main.async {
                self.hasCloudData = false
            }
        }
        
        // Query Active Model from settings
        var proxyActiveModel: String? = nil
        let activeModelName = getSetting(db: db, key: "active_model")
        let activeTimeStr = getSetting(db: db, key: "active_timestamp")
        print("[Swift DEBUG] DB settings: active_model=\(String(describing: activeModelName)), active_timestamp=\(String(describing: activeTimeStr))")
        
        if let activeModelName = activeModelName,
           let activeTimeStr = activeTimeStr {
            
            var cleanTimeStr = activeTimeStr
            if let dotIndex = cleanTimeStr.firstIndex(of: ".") {
                cleanTimeStr = String(cleanTimeStr[..<dotIndex])
            }
            
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone.current
            
            if let activeDate = df.date(from: cleanTimeStr) {
                let elapsed = Date().timeIntervalSince(activeDate)
                print("[Swift DEBUG] Proxy active model check: \(activeModelName) started \(elapsed) seconds ago")
                if elapsed >= 0 && elapsed <= 10.0 {
                    proxyActiveModel = activeModelName
                }
            } else {
                print("[Swift DEBUG] Failed to parse active_timestamp: \(activeTimeStr)")
            }
        }
        
        DispatchQueue.main.async {
            self.lastProxyActiveModel = proxyActiveModel
        }
        
        // Query Local Metrics
        let (sTokens, sTime, sCount) = calculateSessionStats(db: db)
        let (wTokens, wTime, wCount) = calculateWeeklyStats(db: db)
        
        DispatchQueue.main.async {
            self.sessionTokens = sTokens
            self.sessionTime = sTime
            self.sessionRequestCount = sCount
            self.weeklyTokens = wTokens
            self.weeklyTime = wTime
            self.weeklyRequestCount = wCount
        }
    }
    
    func getSetting(db: OpaquePointer?, key: String) -> String? {
        let query = "SELECT value FROM settings WHERE key='\(key)';"
        var statement: OpaquePointer?
        var val: String? = nil
        
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                if let cStr = sqlite3_column_text(statement, 0) {
                    val = String(cString: cStr)
                }
            }
        }
        sqlite3_finalize(statement)
        return val
    }
    
    func saveCookie(cookie: String) {
        guard let url = URL(string: "http://localhost:8080/api/cloud/cookie") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["cookie": cookie]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if error == nil {
                DispatchQueue.main.async {
                    self?.sessionCookie = cookie
                    self?.update()
                }
            }
        }.resume()
    }
    
    func autodetectCookie(completion: @escaping (String?) -> Void) {
        guard let url = URL(string: "http://localhost:8080/api/cloud/autodetect") else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if error == nil, let data = data {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let status = json["status"] as? String, status == "success",
                   let cookie = json["cookie"] as? String {
                    DispatchQueue.main.async {
                        self?.sessionCookie = cookie
                        self?.update()
                        completion(cookie)
                    }
                    return
                }
            }
            completion(nil)
        }.resume()
    }
    
    private func calculateSessionStats(db: OpaquePointer?) -> (Int, Double, Int) {
        var totalTokens = 0
        var totalTime: Double = 0.0
        var count = 0
        
        let resetDate = UserDefaults.standard.object(forKey: "sessionResetTime") as? Date
        let query = "SELECT timestamp, input_tokens, output_tokens, response_time FROM request_logs ORDER BY timestamp DESC;"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            var lastTime: Date? = nil
            let dfWithMillis = DateFormatter()
            dfWithMillis.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
            dfWithMillis.timeZone = TimeZone(secondsFromGMT: 0)
            
            let dfStandard = DateFormatter()
            dfStandard.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            dfStandard.timeZone = TimeZone(secondsFromGMT: 0)
            
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let tsCol = sqlite3_column_text(statement, 0) else { continue }
                let tsStr = String(cString: tsCol)
                
                var date: Date? = dfWithMillis.date(from: tsStr)
                if date == nil {
                    date = dfStandard.date(from: String(tsStr.prefix(19)))
                }
                
                guard let currentDate = date else { continue }
                if let resetLimit = resetDate, currentDate < resetLimit { break }
                
                if let prevTime = lastTime {
                    let diff = prevTime.timeIntervalSince(currentDate)
                    if diff > (30.0 * 60.0) { break }
                }
                
                let inputTokens = Int(sqlite3_column_int(statement, 1))
                let outputTokens = Int(sqlite3_column_int(statement, 2))
                let responseTime = sqlite3_column_double(statement, 3)
                
                totalTokens += (inputTokens + outputTokens)
                totalTime += responseTime
                count += 1
                lastTime = currentDate
            }
        }
        sqlite3_finalize(statement)
        return (totalTokens, totalTime, count)
    }
    
    private func calculateWeeklyStats(db: OpaquePointer?) -> (Int, Double, Int) {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        components.weekday = 2
        components.hour = 0
        components.minute = 0
        components.second = 0
        
        guard let startOfWeek = calendar.date(from: components) else {
            return (0, 0.0, 0)
        }
        
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        df.timeZone = TimeZone(secondsFromGMT: 0)
        let startOfWeekStr = df.string(from: startOfWeek)
        
        let query = "SELECT SUM(input_tokens + output_tokens), SUM(response_time), COUNT(*) FROM request_logs WHERE timestamp >= ?;"
        var statement: OpaquePointer?
        
        var tokens = 0
        var time: Double = 0.0
        var count = 0
        
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, startOfWeekStr, -1, nil)
            if sqlite3_step(statement) == SQLITE_ROW {
                tokens = Int(sqlite3_column_int(statement, 0))
                time = sqlite3_column_double(statement, 1)
                count = Int(sqlite3_column_int(statement, 2))
            }
        }
        sqlite3_finalize(statement)
        return (tokens, time, count)
    }
    
    private func updateMenuBar() {
        let title: String
        
        print("[Swift DEBUG] updateMenuBar: isOllamaOnline=\(isOllamaOnline), hasCloudData=\(hasCloudData), cloudSessionUsedPercent=\(cloudSessionUsedPercent), activeModel=\(String(describing: activeModel))")
        
        let canRefresh = isOllamaOnline && hasCloudData
        
        if !canRefresh {
            title = "Offline"
        } else if let model = activeModel {
            let cleanModelName = model.contains(":") ? String(model.split(separator: ":")[0]) : model
            title = "● \(cleanModelName.prefix(8))"
        } else {
            if showMenuBarPercent {
                let value = menuBarPercentMode == 0 ? max(0, 100 - cloudSessionUsedPercent) : cloudSessionUsedPercent
                title = String(format: "%d%%", Int(value))
            } else {
                title = ""
            }
        }
        
        let image = getAppIcon()
        onUpdate?(title, image)
    }
    
    func saveSettings() {
        UserDefaults.standard.set(limitType, forKey: "limitType")
        UserDefaults.standard.set(sessionLimitTime, forKey: "sessionLimitTime")
        UserDefaults.standard.set(sessionLimitTokens, forKey: "sessionLimitTokens")
        UserDefaults.standard.set(weeklyLimitTime, forKey: "weeklyLimitTime")
        UserDefaults.standard.set(weeklyLimitTokens, forKey: "weeklyLimitTokens")
        UserDefaults.standard.set(showMenuBarPercent, forKey: "showMenuBarPercent")
        UserDefaults.standard.set(menuBarPercentMode, forKey: "menuBarPercentMode")
    }
}

// SwiftUI Popover Content
struct MenuView: View {
    @ObservedObject var state: MonitorState
    
    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                HStack(spacing: 6) {
                    let canRefresh = state.isOllamaOnline && state.hasCloudData
                    
                    if !canRefresh {
                        Circle().fill(Color.red).frame(width: 8, height: 8)
                        Text("Ollama: Offline").font(.headline)
                    } else if let model = state.activeModel {
                        PulsingDot(color: .green)
                        Text(model.contains("-cloud") ? "Cloud: \(model)" : "Local: \(model)")
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                        Text("Ollama: Online").font(.headline)
                    }
                }
                Spacer()
                
                Button(action: {
                    state.update()
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(BorderlessButtonStyle())
            }
            .padding(.bottom, 4)
            
            Divider()
            
            if state.hasCloudData {
                // Official Cloud Limits Card
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Cloud Usage (Official)").font(.caption).bold().foregroundColor(.secondary)
                        Spacer()
                        Text("Pro Plan").font(.caption2).foregroundColor(.blue).bold()
                    }
                    
                    // Session Usage
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(state.menuBarPercentMode == 0 ? "Session Remaining" : "Session Usage").font(.body)
                            Spacer()
                            Text(state.menuBarPercentMode == 0 ? String(format: "%.1f%%", max(0, 100 - state.cloudSessionUsedPercent)) : String(format: "%.1f%% used", state.cloudSessionUsedPercent)).bold()
                        }
                        ProgressView(value: min(1.0, state.cloudSessionUsedPercent / 100.0))
                            .accentColor(state.cloudSessionUsedPercent > 85.0 ? .red : (state.cloudSessionUsedPercent > 60.0 ? .orange : .blue))
                        HStack {
                            Spacer()
                            Text(state.cloudSessionResetText).font(.caption2).foregroundColor(.secondary)
                        }
                        if !state.cloudSessionDetails.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(state.cloudSessionDetails, id: \.name) { detail in
                                    HStack {
                                        Text("• \(detail.name)").font(.system(size: 10)).foregroundColor(.secondary)
                                        Spacer()
                                        Text("\(detail.count) reqs").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
                                    }
                                }
                            }
                            .padding(.top, 2)
                            .padding(.leading, 4)
                        }
                    }
                    
                    // Weekly Usage
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(state.menuBarPercentMode == 0 ? "Weekly Remaining" : "Weekly Usage").font(.body)
                            Spacer()
                            Text(state.menuBarPercentMode == 0 ? String(format: "%.1f%%", max(0, 100 - state.cloudWeeklyUsedPercent)) : String(format: "%.1f%% used", state.cloudWeeklyUsedPercent)).bold()
                        }
                        ProgressView(value: min(1.0, state.cloudWeeklyUsedPercent / 100.0))
                            .accentColor(state.cloudWeeklyUsedPercent > 85.0 ? .red : (state.cloudWeeklyUsedPercent > 60.0 ? .orange : .blue))
                        HStack {
                            Spacer()
                            Text(state.cloudWeeklyResetText).font(.caption2).foregroundColor(.secondary)
                        }
                        if !state.cloudWeeklyDetails.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(state.cloudWeeklyDetails, id: \.name) { detail in
                                    HStack {
                                        Text("• \(detail.name)").font(.system(size: 10)).foregroundColor(.secondary)
                                        Spacer()
                                        Text("\(detail.count) reqs").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
                                    }
                                }
                            }
                            .padding(.top, 2)
                            .padding(.leading, 4)
                        }
                    }
                    
                    Divider().padding(.vertical, 2)
                    
                    HStack {
                        Label("Balance remaining:", systemImage: "dollarsign.circle")
                        Spacer()
                        Text(String(format: "$%.2f", state.cloudBalance)).bold()
                    }
                    .font(.body)
                }
                .padding(10)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.blue.opacity(0.3), lineWidth: 1.5)
                )
            } else {
                VStack(spacing: 8) {
                    Text("No Cloud Data").font(.headline).bold()
                    Text("Please sign in to ollama.com in Google Chrome, then click 'Configure Limits & Scraper...' -> 'Auto-Detect from Chrome'.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(20)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                )
            }
            
            // Settings Toggle Button
            Button(action: {
                withAnimation {
                    state.showSettings.toggle()
                }
            }) {
                HStack {
                    Image(systemName: "gearshape")
                    Text(state.showSettings ? "Hide Settings" : "Settings")
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(BorderlessButtonStyle())
            
            // Settings Drawer
            if state.showSettings {
                VStack(alignment: .leading, spacing: 10) {
                    // Display Mode — affects both modal labels and menu bar
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Display Mode").font(.caption).bold()
                        Picker("Mode", selection: Binding(
                            get: { state.menuBarPercentMode },
                            set: { state.menuBarPercentMode = $0; state.saveSettings(); state.update() }
                        )) {
                            Text("Remaining").tag(0)
                            Text("Used").tag(1)
                        }
                        .pickerStyle(SegmentedPickerStyle())
                    }
                    
                    Divider()
                    
                    // Menu Bar Settings Section
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Menu Bar").font(.caption).bold()
                        
                        Toggle(isOn: Binding(
                            get: { state.showMenuBarPercent },
                            set: { state.showMenuBarPercent = $0; state.saveSettings(); state.update() }
                        )) {
                            Text(state.menuBarPercentMode == 0 ? "Show % Remaining in Menu Bar" : "Show % Used in Menu Bar")
                                .font(.caption)
                        }
                    }
                    
                    Divider()
                    
                    // Scraper Config Section
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ollama Cloud Sync").font(.caption).bold()
                        HStack {
                            Button("Auto-Detect from Chrome") {
                                state.autodetectCookie { _ in }
                            }
                            Spacer()
                        }
                        if !state.sessionCookie.isEmpty {
                            Text("Status: Connected (Chrome session active)")
                                .font(.system(size: 8))
                                .foregroundColor(.green)
                        } else {
                            Text("Status: Not Connected (Please log in to ollama.com in Chrome)")
                                .font(.system(size: 8))
                                .foregroundColor(.red)
                        }
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(6)
            }
            
            Divider()
            
            // Footer Control Buttons
            HStack {
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.top, 4)
        }
        .padding(16)
        .frame(width: 300)
    }
    
    func formatTime(_ seconds: Double) -> String {
        let sec = Int(seconds)
        let hours = sec / 3600
        let minutes = (sec % 3600) / 60
        let secs = sec % 60
        
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m \(secs)s"
        } else {
            return "\(secs)s"
        }
    }
    
    func formatTokens(_ count: Int) -> String {
        if count >= 1000000 {
            return String(format: "%.1fM tkns", Double(count) / 1000000.0)
        } else if count >= 1000 {
            return String(format: "%.1fK tkns", Double(count) / 1000.0)
        } else {
            return "\(count) tkns"
        }
    }
}

// App Delegate to manage NSPopover life cycle
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var state: MonitorState?
    var daemonProcess: Process?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        
        let state = MonitorState()
        self.state = state
        
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 440)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuView(state: state))
        self.popover = popover
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
            
            button.title = "Ollama: Check"
            button.image = state.getAppIcon()
            
            state.onUpdate = { [weak button] title, image in
                button?.title = title
                button?.image = image
            }
        }
        
        startDaemon()
    }
    
    func startDaemon() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        
        let currentDir = FileManager.default.currentDirectoryPath
        let venvPython = "\(currentDir)/.venv/bin/python3"
        let pythonPath = FileManager.default.fileExists(atPath: venvPython) ? venvPython : "python3"
        
        process.arguments = [pythonPath, "ollama_monitor.py"]
        process.currentDirectoryURL = URL(fileURLWithPath: currentDir)
        
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        
        do {
            try process.run()
            self.daemonProcess = process
            print("Started Python background daemon with: \(pythonPath)")
        } catch {
            print("Failed to run Python background daemon: \(error)")
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        if let daemon = daemonProcess, daemon.isRunning {
            daemon.terminate()
        }
    }
    
    @objc func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button, let popover = popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

// SwiftUI Main Entry Point
@main
struct OllamaMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
