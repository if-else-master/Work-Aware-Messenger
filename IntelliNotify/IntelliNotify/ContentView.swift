import SwiftUI
import Foundation
import UserNotifications
import Combine

#if os(iOS)
import DeviceActivity
import FamilyControls
import ManagedSettings
#endif

#if canImport(MessageUI)
import MessageUI
#endif

// MARK: - 數據模型
struct Message: Identifiable, Codable {
    let id: UUID
    let content: String
    let sender: String
    let timestamp: Date
    var priority: MessagePriority = .unknown
    var isProcessed: Bool = false
    
    init(content: String, sender: String, timestamp: Date = Date()) {
        self.id = UUID()
        self.content = content
        self.sender = sender
        self.timestamp = timestamp
    }
    
    // 自定義 CodingKeys 來處理編碼/解碼
    enum CodingKeys: String, CodingKey {
        case id, content, sender, timestamp, priority, isProcessed
    }
    
    // 自定義初始化器用於解碼
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        content = try container.decode(String.self, forKey: .content)
        sender = try container.decode(String.self, forKey: .sender)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        priority = try container.decodeIfPresent(MessagePriority.self, forKey: .priority) ?? .unknown
        isProcessed = try container.decodeIfPresent(Bool.self, forKey: .isProcessed) ?? false
    }
}

enum MessagePriority: String, Codable, CaseIterable {
    case urgent = "urgent"
    case important = "important"
    case normal = "normal"
    case low = "low"
    case unknown = "unknown"
    
    var displayName: String {
        switch self {
        case .urgent: return "緊急"
        case .important: return "重要"
        case .normal: return "一般"
        case .low: return "低"
        case .unknown: return "未知"
        }
    }
    
    var color: Color {
        switch self {
        case .urgent: return .red
        case .important: return .orange
        case .normal: return .blue
        case .low: return .gray
        case .unknown: return .secondary
        }
    }
}

enum WorkStatus: String, Codable {
    case working = "working"
    case resting = "resting"
    case offline = "offline"
    case unknown = "unknown"
    
    var displayName: String {
        switch self {
        case .working: return "工作中"
        case .resting: return "休息中"
        case .offline: return "離線"
        case .unknown: return "未知"
        }
    }
}

struct UserActivityData: Codable {
    let currentApp: String?
    let screenTime: TimeInterval
    let workApps: [String]
    let timestamp: Date
    let deviceType: String // iPhone, iPad, MacBook
}

struct GeminiRequest: Codable {
    let contents: [GeminiContent]
    let generationConfig: GeminiGenerationConfig
}

struct GeminiContent: Codable {
    let parts: [GeminiPart]
}

struct GeminiPart: Codable {
    let text: String
}

struct GeminiGenerationConfig: Codable {
    let temperature: Double
    let topK: Int
    let topP: Double
    let maxOutputTokens: Int
}

struct GeminiResponse: Codable {
    let candidates: [GeminiCandidate]
}

struct GeminiCandidate: Codable {
    let content: GeminiContent
}

struct AnalysisResult: Codable {
    let messagePriority: String
    let workStatus: String
    let shouldNotifyImmediately: Bool
    let reasoning: String
    let confidence: Double
}

// MARK: - Gemini API 服務
class GeminiService: ObservableObject {
    private let apiKey = "YOUR_GEMINI_API_KEY" // 請替換為實際的 API Key
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent"
    
    func analyzeMessageAndWorkStatus(
        message: Message,
        activityData: UserActivityData,
        screenTimeData: [String: TimeInterval],
        completion: @escaping (Result<AnalysisResult, Error>) -> Void
    ) {
        let prompt = createAnalysisPrompt(message: message, activityData: activityData, screenTimeData: screenTimeData)
        
        let request = GeminiRequest(
            contents: [GeminiContent(parts: [GeminiPart(text: prompt)])],
            generationConfig: GeminiGenerationConfig(
                temperature: 0.1,
                topK: 40,
                topP: 0.95,
                maxOutputTokens: 1024
            )
        )
        
        guard let url = URL(string: "\(baseURL)?key=\(apiKey)") else {
            completion(.failure(NSError(domain: "Invalid URL", code: 0, userInfo: nil)))
            return
        }
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            urlRequest.httpBody = try JSONEncoder().encode(request)
        } catch {
            completion(.failure(error))
            return
        }
        
        URLSession.shared.dataTask(with: urlRequest) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let data = data else {
                completion(.failure(NSError(domain: "No data", code: 0, userInfo: nil)))
                return
            }
            
            do {
                let geminiResponse = try JSONDecoder().decode(GeminiResponse.self, from: data)
                if let firstCandidate = geminiResponse.candidates.first,
                   let responseText = firstCandidate.content.parts.first?.text {
                    let analysisResult = self.parseAnalysisResult(from: responseText)
                    completion(.success(analysisResult))
                } else {
                    completion(.failure(NSError(domain: "Invalid response", code: 0, userInfo: nil)))
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
    
    private func createAnalysisPrompt(message: Message, activityData: UserActivityData, screenTimeData: [String: TimeInterval]) -> String {
        let screenTimeText = screenTimeData.map { "\($0.key): \(Int($0.value/60))分鐘" }.joined(separator: ", ")
        
        return """
        請分析以下訊息和用戶狀態，並以JSON格式回覆：

        訊息內容：
        - 發送者：\(message.sender)
        - 內容：\(message.content)
        - 時間：\(message.timestamp)

        用戶活動數據：
        - 當前使用的應用程式：\(activityData.currentApp ?? "未知")
        - 設備類型：\(activityData.deviceType)
        - 螢幕使用時間：\(Int(activityData.screenTime/60))分鐘
        - 工作相關應用程式：\(activityData.workApps.joined(separator: ", "))

        今日應用使用時間：
        \(screenTimeText)

        請根據以下標準分析：

        1. 訊息優先級判斷：
        - urgent: 緊急（如：工作緊急事項、家庭緊急狀況、健康相關）
        - important: 重要（如：工作相關、重要約會提醒）
        - normal: 一般（如：朋友聊天、一般通知）
        - low: 低（如：廣告、無關緊要的通知）

        2. 工作狀態判斷：
        - working: 正在使用工作相關應用程式
        - resting: 在休息或使用娛樂應用程式
        - offline: 長時間未使用設備
        - unknown: 無法確定

        3. 是否立即通知：
        - 如果訊息是緊急的，無論工作狀態都應立即通知
        - 如果訊息重要但用戶正在工作，可以延遲通知
        - 如果用戶在休息，重要訊息可以立即通知

        請以此JSON格式回覆：
        {
            "messagePriority": "urgent|important|normal|low",
            "workStatus": "working|resting|offline|unknown",
            "shouldNotifyImmediately": true|false,
            "reasoning": "分析理由",
            "confidence": 0.0-1.0
        }
        """
    }
    
    private func parseAnalysisResult(from text: String) -> AnalysisResult {
        // 嘗試解析JSON回應
        if let jsonStart = text.range(of: "{"),
           let jsonEnd = text.range(of: "}", options: .backwards) {
            let jsonString = String(text[jsonStart.lowerBound...jsonEnd.upperBound])
            if let data = jsonString.data(using: .utf8),
               let result = try? JSONDecoder().decode(AnalysisResult.self, from: data) {
                return result
            }
        }
        
        // 如果JSON解析失敗，返回默認值
        return AnalysisResult(
            messagePriority: "normal",
            workStatus: "unknown",
            shouldNotifyImmediately: false,
            reasoning: "無法解析AI回應",
            confidence: 0.5
        )
    }
}

// MARK: - 設備活動監控服務
class DeviceActivityService: ObservableObject {
    @Published var currentWorkStatus: WorkStatus = .unknown
    @Published var screenTimeData: [String: TimeInterval] = [:]
    
    private let workApps = [
        "com.microsoft.Office.Word",
        "com.microsoft.Office.Excel",
        "com.microsoft.Office.PowerPoint",
        "com.apple.mail",
        "com.apple.MobileSMS",
        "com.slack.Slack",
        "com.microsoft.teams",
        "com.zoom.ZoomRooms",
        "com.notion.Notion",
        "com.culturedcode.ThingsiPhone",
        "com.omnigroup.OmniFocus3",
        "com.apple.dt.Xcode"
    ]
    
    func getCurrentActivityData() -> UserActivityData {
        return UserActivityData(
            currentApp: getCurrentApp(),
            screenTime: getTotalScreenTime(),
            workApps: workApps,
            timestamp: Date(),
            deviceType: getDeviceType()
        )
    }
    
    private func getCurrentApp() -> String? {
        // 在實際應用中，這需要使用 DeviceActivity 框架
        // 這裡返回模擬數據
        return "com.apple.MobileSMS"
    }
    
    private func getTotalScreenTime() -> TimeInterval {
        // 在實際應用中，這需要使用 Screen Time API
        return screenTimeData.values.reduce(0, +)
    }
    
    private func getDeviceType() -> String {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #elseif os(macOS)
        return "MacBook"
        #else
        return "Unknown"
        #endif
    }
    
    func requestScreenTimeAccess() {
        #if os(iOS)
        if #available(iOS 15.0, *) {
            Task {
                do {
                    try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
                    await MainActor.run {
                        print("Screen Time access approved")
                        self.startMonitoring()
                    }
                } catch {
                    await MainActor.run {
                        print("Screen Time access denied: \(error)")
                    }
                }
            }
        } else {
            // iOS 15 以下版本的兼容处理
            print("Screen Time API requires iOS 15.0 or later")
            self.startMonitoring() // 使用模拟数据
        }
        #endif
    }
    
    private func startMonitoring() {
        // 實現螢幕時間監控邏輯
        // 這裡添加模擬數據
        DispatchQueue.main.async {
            self.screenTimeData = [
                "工作應用": 180 * 60, // 3小時
                "社交應用": 45 * 60,  // 45分鐘
                "娛樂應用": 30 * 60   // 30分鐘
            ]
        }
    }
}

// MARK: - 訊息管理服務
class MessageService: ObservableObject {
    @Published var messages: [Message] = []
    @Published var pendingMessages: [Message] = []
    
    private let geminiService = GeminiService()
    private let deviceService = DeviceActivityService()
    
    func processIncomingMessage(_ message: Message) {
        let activityData = deviceService.getCurrentActivityData()
        
        geminiService.analyzeMessageAndWorkStatus(
            message: message,
            activityData: activityData,
            screenTimeData: deviceService.screenTimeData
        ) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let analysis):
                    self?.handleAnalysisResult(message: message, analysis: analysis)
                case .failure(let error):
                    print("分析失敗: \(error)")
                    self?.handleDefaultMessage(message)
                }
            }
        }
    }
    
    private func handleAnalysisResult(message: Message, analysis: AnalysisResult) {
        var updatedMessage = message
        updatedMessage.priority = MessagePriority(rawValue: analysis.messagePriority) ?? .normal
        updatedMessage.isProcessed = true
        
        messages.append(updatedMessage)
        
        if analysis.shouldNotifyImmediately {
            sendImmediateNotification(message: updatedMessage, reasoning: analysis.reasoning)
        } else {
            pendingMessages.append(updatedMessage)
            scheduleDelayedNotification(message: updatedMessage)
        }
    }
    
    private func handleDefaultMessage(_ message: Message) {
        var updatedMessage = message
        updatedMessage.priority = .normal
        updatedMessage.isProcessed = true
        messages.append(updatedMessage)
        pendingMessages.append(updatedMessage)
    }
    
    private func sendImmediateNotification(message: Message, reasoning: String) {
        let content = UNMutableNotificationContent()
        content.title = "重要訊息 - \(message.sender)"
        content.body = message.content
        content.sound = .default
        content.userInfo = ["reasoning": reasoning]
        
        let request = UNNotificationRequest(
            identifier: message.id.uuidString,
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    private func scheduleDelayedNotification(message: Message) {
        // 延遲通知邏輯，可以根據工作狀態調整延遲時間
        let delay: TimeInterval = 30 * 60 // 30分鐘後通知
        
        let content = UNMutableNotificationContent()
        content.title = "訊息提醒 - \(message.sender)"
        content.body = message.content
        content.sound = .default
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        let request = UNNotificationRequest(
            identifier: "delayed_\(message.id.uuidString)",
            content: content,
            trigger: trigger
        )
        
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - 主要視圖
struct ContentView: View {
    @StateObject private var messageService = MessageService()
    @StateObject private var deviceService = DeviceActivityService()
    @State private var showingAddMessage = false
    @State private var newMessageContent = ""
    @State private var newMessageSender = ""
    
    var body: some View {
        NavigationView {
            VStack {
                // 狀態卡片
                StatusCard(deviceService: deviceService)
                
                // 訊息列表
                List {
                    Section("處理中的訊息") {
                        ForEach(messageService.messages) { message in
                            MessageRow(message: message)
                        }
                    }
                    
                    if !messageService.pendingMessages.isEmpty {
                        Section("待處理訊息") {
                            ForEach(messageService.pendingMessages) { message in
                                MessageRow(message: message)
                            }
                        }
                    }
                }
            }
            .navigationTitle("智能訊息管理")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("添加測試訊息") {
                        showingAddMessage = true
                    }
                }
            }
            .sheet(isPresented: $showingAddMessage) {
                AddMessageView(
                    messageContent: $newMessageContent,
                    messageSender: $newMessageSender,
                    onAdd: { content, sender in
                        let message = Message(
                            content: content,
                            sender: sender,
                            timestamp: Date()
                        )
                        messageService.processIncomingMessage(message)
                        showingAddMessage = false
                        newMessageContent = ""
                        newMessageSender = ""
                    }
                )
            }
        }
        .onAppear {
            requestNotificationPermission()
            deviceService.requestScreenTimeAccess()
        }
    }
    
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if granted {
                print("通知權限已授予")
            } else {
                print("通知權限被拒絕")
            }
        }
    }
}

// MARK: - 狀態卡片視圖
struct StatusCard: View {
    @ObservedObject var deviceService: DeviceActivityService
    
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading) {
                    Text("工作狀態")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(deviceService.currentWorkStatus.displayName)
                        .font(.headline)
                        .foregroundColor(.primary)
                }
                Spacer()
                
                VStack(alignment: .trailing) {
                    Text("螢幕時間")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(Int(deviceService.screenTimeData.values.reduce(0, +) / 3600))小時")
                        .font(.headline)
                        .foregroundColor(.primary)
                }
            }
            
            if !deviceService.screenTimeData.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("應用使用時間")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    ForEach(Array(deviceService.screenTimeData.keys), id: \.self) { app in
                        HStack {
                            Text(app)
                                .font(.caption)
                            Spacer()
                            Text("\(Int((deviceService.screenTimeData[app] ?? 0) / 60))分鐘")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
        .padding(.horizontal)
    }
}

// MARK: - 訊息行視圖
struct MessageRow: View {
    let message: Message
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(message.sender)
                    .font(.headline)
                Spacer()
                Text(message.priority.displayName)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(message.priority.color.opacity(0.2))
                    .foregroundColor(message.priority.color)
                    .cornerRadius(8)
            }
            
            Text(message.content)
                .font(.body)
                .foregroundColor(.primary)
            
            Text(message.timestamp, style: .time)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 添加訊息視圖
struct AddMessageView: View {
    @Binding var messageContent: String
    @Binding var messageSender: String
    let onAdd: (String, String) -> Void
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            Form {
                Section("訊息詳情") {
                    TextField("發送者", text: $messageSender)
                    TextField("訊息內容", text: $messageContent, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("添加測試訊息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("添加") {
                        onAdd(messageContent, messageSender)
                    }
                    .disabled(messageContent.isEmpty || messageSender.isEmpty)
                }
            }
        }
    }
}

// MARK: - 應用程式入口
