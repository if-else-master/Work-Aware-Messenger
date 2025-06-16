import SwiftUI
import Foundation
import UserNotifications
import Combine
import EventKit

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
    
    enum CodingKeys: String, CodingKey {
        case id, content, sender, timestamp, priority, isProcessed
    }
    
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
    case inMeeting = "inMeeting"
    case free = "free"
    case unknown = "unknown"
    
    var displayName: String {
        switch self {
        case .working: return "工作中"
        case .resting: return "休息中"
        case .inMeeting: return "會議中"
        case .free: return "空閒"
        case .unknown: return "未知"
        }
    }
}

// EventKit 相關模型
struct CalendarEvent: Identifiable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let notes: String?
    let location: String?
    let calendarTitle: String
    let isAllDay: Bool
    
    init(from ekEvent: EKEvent) {
        self.id = ekEvent.eventIdentifier
        self.title = ekEvent.title
        self.startDate = ekEvent.startDate
        self.endDate = ekEvent.endDate
        self.notes = ekEvent.notes
        self.location = ekEvent.location
        self.calendarTitle = ekEvent.calendar.title
        self.isAllDay = ekEvent.isAllDay
    }
}

struct UserActivityData: Codable {
    let currentEvent: String?
    let workStatus: WorkStatus
    let timestamp: Date
    let deviceType: String
    let upcomingEvents: [String]
}

// Gemini API 相關結構保持不變
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

// MARK: - API 設定管理
class APISettingsManager: ObservableObject {
    @Published var apiKey: String = ""
    @Published var isAPIConfigured: Bool = false
    
    private let userDefaults = UserDefaults.standard
    private let apiKeyKey = "GeminiAPIKey"
    
    init() {
        loadAPIKey()
    }
    
    func saveAPIKey(_ key: String) {
        apiKey = key
        isAPIConfigured = !key.isEmpty
        userDefaults.set(key, forKey: apiKeyKey)
    }
    
    private func loadAPIKey() {
        apiKey = userDefaults.string(forKey: apiKeyKey) ?? ""
        isAPIConfigured = !apiKey.isEmpty
    }
    
    func clearAPIKey() {
        apiKey = ""
        isAPIConfigured = false
        userDefaults.removeObject(forKey: apiKeyKey)
    }
}

// MARK: - EventKit 服務
class CalendarService: ObservableObject {
    @Published var events: [CalendarEvent] = []
    @Published var authorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var isAuthorized: Bool = false
    @Published var currentWorkStatus: WorkStatus = .unknown
    
    private let eventStore = EKEventStore()
    
    init() {
        checkAuthorizationStatus()
    }
    
    func checkAuthorizationStatus() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        isAuthorized = authorizationStatus == .authorized
        
        if isAuthorized {
            loadEvents()
        }
    }
    
    func requestCalendarAccess() {
        eventStore.requestAccess(to: .event) { [weak self] granted, error in
            DispatchQueue.main.async {
                self?.authorizationStatus = EKEventStore.authorizationStatus(for: .event)
                self?.isAuthorized = granted
                
                if granted {
                    self?.loadEvents()
                } else {
                    print("行事曆存取被拒絕: \(error?.localizedDescription ?? "未知錯誤")")
                }
            }
        }
    }
    
    func loadEvents() {
        guard isAuthorized else { return }
        
        let calendar = Calendar.current
        let startDate = calendar.startOfDay(for: Date())
        let endDate = calendar.date(byAdding: .day, value: 7, to: startDate) ?? Date()
        
        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
        let ekEvents = eventStore.events(matching: predicate)
        
        events = ekEvents.map { CalendarEvent(from: $0) }
        updateWorkStatus()
    }
    
    private func updateWorkStatus() {
        let now = Date()
        let currentEvents = events.filter { event in
            now >= event.startDate && now <= event.endDate
        }
        
        if !currentEvents.isEmpty {
            // 如果有正在進行的事件，檢查是否為工作相關
            let hasWorkEvent = currentEvents.contains { event in
                isWorkRelatedEvent(event)
            }
            
            currentWorkStatus = hasWorkEvent ? .working : .inMeeting
        } else {
            // 檢查接下來一小時內是否有事件
            let oneHourLater = Calendar.current.date(byAdding: .hour, value: 1, to: now) ?? now
            let upcomingEvents = events.filter { event in
                event.startDate >= now && event.startDate <= oneHourLater
            }
            
            currentWorkStatus = upcomingEvents.isEmpty ? .free : .resting
        }
    }
    
    private func isWorkRelatedEvent(_ event: CalendarEvent) -> Bool {
        let workKeywords = ["會議", "meeting", "工作", "work", "專案", "project", "客戶", "client", "討論", "review"]
        let eventText = (event.title + " " + (event.notes ?? "")).lowercased()
        
        return workKeywords.contains { keyword in
            eventText.contains(keyword.lowercased())
        }
    }
    
    func createEvent(title: String, startDate: Date, endDate: Date, notes: String? = nil, location: String? = nil) throws {
        guard isAuthorized else {
            throw NSError(domain: "Calendar", code: 1, userInfo: [NSLocalizedDescriptionKey: "沒有行事曆權限"])
        }
        
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.notes = notes
        event.location = location
        event.calendar = eventStore.defaultCalendarForNewEvents
        
        try eventStore.save(event, span: .thisEvent)
        loadEvents() // 重新載入事件
    }
    
    func updateEvent(eventId: String, title: String? = nil, startDate: Date? = nil, endDate: Date? = nil, notes: String? = nil, location: String? = nil) throws {
        guard isAuthorized else {
            throw NSError(domain: "Calendar", code: 1, userInfo: [NSLocalizedDescriptionKey: "沒有行事曆權限"])
        }
        
        guard let event = eventStore.event(withIdentifier: eventId) else {
            throw NSError(domain: "Calendar", code: 2, userInfo: [NSLocalizedDescriptionKey: "找不到指定的事件"])
        }
        
        if let title = title { event.title = title }
        if let startDate = startDate { event.startDate = startDate }
        if let endDate = endDate { event.endDate = endDate }
        if let notes = notes { event.notes = notes }
        if let location = location { event.location = location }
        
        try eventStore.save(event, span: .thisEvent)
        loadEvents() // 重新載入事件
    }
    
    func deleteEvent(eventId: String) throws {
        guard isAuthorized else {
            throw NSError(domain: "Calendar", code: 1, userInfo: [NSLocalizedDescriptionKey: "沒有行事曆權限"])
        }
        
        guard let event = eventStore.event(withIdentifier: eventId) else {
            throw NSError(domain: "Calendar", code: 2, userInfo: [NSLocalizedDescriptionKey: "找不到指定的事件"])
        }
        
        try eventStore.remove(event, span: .thisEvent)
        loadEvents() // 重新載入事件
    }
    
    func getCurrentActivityData() -> UserActivityData {
        let now = Date()
        let currentEvent = events.first { event in
            now >= event.startDate && now <= event.endDate
        }
        
        let upcomingEvents = events.filter { event in
            let oneHourLater = Calendar.current.date(byAdding: .hour, value: 1, to: now) ?? now
            return event.startDate >= now && event.startDate <= oneHourLater
        }.map { $0.title }
        
        return UserActivityData(
            currentEvent: currentEvent?.title,
            workStatus: currentWorkStatus,
            timestamp: Date(),
            deviceType: getDeviceType(),
            upcomingEvents: upcomingEvents
        )
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
}

// MARK: - Gemini API 服務
class GeminiService: ObservableObject {
    @Published var apiSettingsManager = APISettingsManager()
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent"
    
    func analyzeMessageAndWorkStatus(
        message: Message,
        activityData: UserActivityData,
        completion: @escaping (Result<AnalysisResult, Error>) -> Void
    ) {
        guard !apiSettingsManager.apiKey.isEmpty else {
            completion(.failure(NSError(domain: "API Key not configured", code: 0, userInfo: [NSLocalizedDescriptionKey: "請先設定 Gemini API Key"])))
            return
        }
        
        let prompt = createAnalysisPrompt(message: message, activityData: activityData)
        
        let request = GeminiRequest(
            contents: [GeminiContent(parts: [GeminiPart(text: prompt)])],
            generationConfig: GeminiGenerationConfig(
                temperature: 0.1,
                topK: 40,
                topP: 0.95,
                maxOutputTokens: 1024
            )
        )
        
        guard let url = URL(string: "\(baseURL)?key=\(apiSettingsManager.apiKey)") else {
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
    
    private func createAnalysisPrompt(message: Message, activityData: UserActivityData) -> String {
        let upcomingEventsText = activityData.upcomingEvents.isEmpty ? "無" : activityData.upcomingEvents.joined(separator: ", ")
        
        return """
        請分析以下訊息和用戶狀態，並以JSON格式回覆：

        訊息內容：
        - 發送者：\(message.sender)
        - 內容：\(message.content)
        - 時間：\(message.timestamp)

        用戶活動數據：
        - 當前事件：\(activityData.currentEvent ?? "無")
        - 工作狀態：\(activityData.workStatus.displayName)
        - 設備類型：\(activityData.deviceType)
        - 接下來一小時的事件：\(upcomingEventsText)

        請根據以下標準分析：

        1. 訊息優先級判斷：
        - urgent: 緊急（如：工作緊急事項、家庭緊急狀況、健康相關）
        - important: 重要（如：工作相關、重要約會提醒）
        - normal: 一般（如：朋友聊天、一般通知）
        - low: 低（如：廣告、無關緊要的通知）

        2. 工作狀態判斷：
        - working: 正在工作或在工作相關會議中
        - inMeeting: 在會議中但非工作相關
        - resting: 休息中但即將有事件
        - free: 完全空閒
        - unknown: 無法確定

        3. 是否立即通知：
        - 如果訊息是緊急的，無論工作狀態都應立即通知
        - 如果訊息重要但用戶正在會議中，應延遲通知
        - 如果用戶空閒，重要訊息可以立即通知

        請以此JSON格式回覆：
        {
            "messagePriority": "urgent|important|normal|low",
            "workStatus": "working|inMeeting|resting|free|unknown",
            "shouldNotifyImmediately": true|false,
            "reasoning": "分析理由",
            "confidence": 0.0-1.0
        }
        """
    }
    
    private func parseAnalysisResult(from text: String) -> AnalysisResult {
        if let jsonStart = text.range(of: "{"),
           let jsonEnd = text.range(of: "}", options: .backwards) {
            let jsonString = String(text[jsonStart.lowerBound...jsonEnd.upperBound])
            if let data = jsonString.data(using: .utf8),
               let result = try? JSONDecoder().decode(AnalysisResult.self, from: data) {
                return result
            }
        }
        
        return AnalysisResult(
            messagePriority: "normal",
            workStatus: "unknown",
            shouldNotifyImmediately: false,
            reasoning: "無法解析AI回應",
            confidence: 0.5
        )
    }
}

// MARK: - 訊息管理服務
class MessageService: ObservableObject {
    @Published var messages: [Message] = []
    @Published var pendingMessages: [Message] = []
    
    let geminiService = GeminiService()
    private let calendarService = CalendarService()
    
    func processIncomingMessage(_ message: Message) {
        let activityData = calendarService.getCurrentActivityData()
        
        geminiService.analyzeMessageAndWorkStatus(
            message: message,
            activityData: activityData
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
    @StateObject private var calendarService = CalendarService()
    @State private var showingAddMessage = false
    @State private var showingAPISettings = false
    @State private var showingCalendarView = false
    @State private var newMessageContent = ""
    @State private var newMessageSender = ""
    
    var body: some View {
        NavigationView {
            VStack {
                // API 狀態提示
                if !messageService.geminiService.apiSettingsManager.isAPIConfigured {
                    APIStatusBanner(showingAPISettings: $showingAPISettings)
                }
                
                // 行事曆權限狀態提示
                if !calendarService.isAuthorized {
                    CalendarPermissionBanner(calendarService: calendarService)
                }
                
                // 狀態卡片
                StatusCard(calendarService: calendarService)
                
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
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button(action: {
                        showingCalendarView = true
                    }) {
                        Image(systemName: "calendar")
                            .foregroundColor(calendarService.isAuthorized ? .blue : .gray)
                    }
                    
                    Button(action: {
                        showingAPISettings = true
                    }) {
                        Image(systemName: messageService.geminiService.apiSettingsManager.isAPIConfigured ? "key.fill" : "key")
                            .foregroundColor(messageService.geminiService.apiSettingsManager.isAPIConfigured ? .green : .orange)
                    }
                    
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
            .sheet(isPresented: $showingAPISettings) {
                APISettingsView(apiSettingsManager: messageService.geminiService.apiSettingsManager)
            }
            .sheet(isPresented: $showingCalendarView) {
                CalendarManagementView(calendarService: calendarService)
            }
        }
        .onAppear {
            requestNotificationPermission()
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

// MARK: - 行事曆權限橫幅
struct CalendarPermissionBanner: View {
    @ObservedObject var calendarService: CalendarService
    
    var body: some View {
        HStack {
            Image(systemName: "calendar.badge.exclamationmark")
                .foregroundColor(.blue)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("需要行事曆權限")
                    .font(.headline)
                    .foregroundColor(.primary)
                Text("允許存取行事曆以提供更精確的工作狀態分析")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button("授權") {
                calendarService.requestCalendarAccess()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding()
        .background(Color.blue.opacity(0.1))
        .cornerRadius(12)
        .padding(.horizontal)
    }
}

// MARK: - API 狀態橫幅
struct APIStatusBanner: View {
    @Binding var showingAPISettings: Bool
    
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("需要設定 API Key")
                    .font(.headline)
                    .foregroundColor(.primary)
                Text("點擊設定 Gemini API Key 以啟用智能分析功能")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button("設定") {
                showingAPISettings = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
        .padding(.horizontal)
    }
}

// MARK: - 狀態卡片視圖
struct StatusCard: View {
    @ObservedObject var calendarService: CalendarService
    
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading) {
                    Text("工作狀態")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(calendarService.currentWorkStatus.displayName)
                        .font(.headline)
                        .foregroundColor(.primary)
                }
                Spacer()
                
                VStack(alignment: .trailing) {
                    Text("今日事件")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(calendarService.events.filter { Calendar.current.isDateInToday($0.startDate) }.count)個")
                        .font(.headline)
                        .foregroundColor(.primary)
                }
            }
            
            if calendarService.isAuthorized {
                let todayEvents = calendarService.events.filter { Calendar.current.isDateInToday($0.startDate) }.prefix(3)
                if !todayEvents.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("今日行程")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        ForEach(Array(todayEvents), id: \.id) { event in
                            HStack {
                                Text(event.title)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer()
                                Text(event.startDate, style: .time)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
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

// MARK: - 行事曆管理視圖
struct CalendarManagementView: View {
    @ObservedObject var calendarService: CalendarService
    @Environment(\.presentationMode) var presentationMode
    @State private var showingAddEvent = false
    @State private var selectedEvent: CalendarEvent?
    @State private var showingEventDetail = false
    
    var body: some View {
        NavigationView {
            Group {
                if calendarService.isAuthorized {
                    List {
                        Section("近期事件") {
                            ForEach(calendarService.events, id: \.id) { event in
                                CalendarEventRow(event: event) {
                                    selectedEvent = event
                                    showingEventDetail = true
                                }
                            }
                        }
                    }
                } else {
                    VStack(spacing: 20) {
                        Image(systemName: "calendar.badge.exclamationmark")
                            .font(.system(size: 60))
                            .foregroundColor(.blue)
                        
                        Text("需要行事曆權限")
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        Text("請允許此應用程式存取您的行事曆以檢視和管理事件")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                        
                        Button("授權存取") {
                            calendarService.requestCalendarAccess()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    .padding()
                }
            }
            .navigationTitle("行事曆管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("關閉") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                
                if calendarService.isAuthorized {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("新增事件") {
                            showingAddEvent = true
                        }
                    }
                }
            }
            .sheet(isPresented: $showingAddEvent) {
                AddEventView(calendarService: calendarService)
            }
            .sheet(isPresented: $showingEventDetail) {
                if let event = selectedEvent {
                    EventDetailView(event: event, calendarService: calendarService)
                }
            }
        }
    }
}

// MARK: - 行事曆事件行視圖
struct CalendarEventRow: View {
    let event: CalendarEvent
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(event.title)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Spacer()
                    if event.isAllDay {
                        Text("全天")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.2))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                    }
                }
                
                HStack {
                    Text(event.startDate, style: .date)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if !event.isAllDay {
                        Text(event.startDate, style: .time)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("-")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(event.endDate, style: .time)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Text(event.calendarTitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if let location = event.location, !location.isEmpty {
                    HStack {
                        Image(systemName: "location")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(location)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 新增事件視圖
struct AddEventView: View {
    @ObservedObject var calendarService: CalendarService
    @Environment(\.presentationMode) var presentationMode
    
    @State private var title = ""
    @State private var startDate = Date()
    @State private var endDate = Date().addingTimeInterval(3600) // 1小時後
    @State private var notes = ""
    @State private var location = ""
    @State private var isAllDay = false
    @State private var showingError = false
    @State private var errorMessage = ""
    
    var body: some View {
        NavigationView {
            Form {
                Section("事件詳情") {
                    TextField("標題", text: $title)
                    
                    Toggle("全天事件", isOn: $isAllDay)
                    
                    DatePicker("開始時間", selection: $startDate, displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute])
                    
                    DatePicker("結束時間", selection: $endDate, displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute])
                    
                    TextField("地點（選填）", text: $location)
                    
                    TextField("備註（選填）", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("新增事件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("儲存") {
                        saveEvent()
                    }
                    .disabled(title.isEmpty)
                }
            }
            .alert("錯誤", isPresented: $showingError) {
                Button("確定") { }
            } message: {
                Text(errorMessage)
            }
        }
    }
    
    private func saveEvent() {
        do {
            try calendarService.createEvent(
                title: title,
                startDate: startDate,
                endDate: endDate,
                notes: notes.isEmpty ? nil : notes,
                location: location.isEmpty ? nil : location
            )
            presentationMode.wrappedValue.dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }
}

// MARK: - 事件詳情視圖
struct EventDetailView: View {
    let event: CalendarEvent
    @ObservedObject var calendarService: CalendarService
    @Environment(\.presentationMode) var presentationMode
    
    @State private var showingEditView = false
    @State private var showingDeleteAlert = false
    @State private var showingError = false
    @State private var errorMessage = ""
    
    var body: some View {
        NavigationView {
            Form {
                Section("事件詳情") {
                    DetailRow(title: "標題", value: event.title)
                    
                    DetailRow(title: "開始時間", value: formatDate(event.startDate, isAllDay: event.isAllDay))
                    
                    DetailRow(title: "結束時間", value: formatDate(event.endDate, isAllDay: event.isAllDay))
                    
                    if let location = event.location, !location.isEmpty {
                        DetailRow(title: "地點", value: location)
                    }
                    
                    DetailRow(title: "行事曆", value: event.calendarTitle)
                    
                    if event.isAllDay {
                        DetailRow(title: "類型", value: "全天事件")
                    }
                }
                
                if let notes = event.notes, !notes.isEmpty {
                    Section("備註") {
                        Text(notes)
                            .foregroundColor(.secondary)
                    }
                }
                
                Section {
                    Button("編輯事件") {
                        showingEditView = true
                    }
                    
                    Button("刪除事件") {
                        showingDeleteAlert = true
                    }
                    .foregroundColor(.red)
                }
            }
            .navigationTitle("事件詳情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("關閉") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingEditView) {
                EditEventView(event: event, calendarService: calendarService)
            }
            .alert("確認刪除", isPresented: $showingDeleteAlert) {
                Button("取消", role: .cancel) { }
                Button("刪除", role: .destructive) {
                    deleteEvent()
                }
            } message: {
                Text("確定要刪除這個事件嗎？此操作無法復原。")
            }
            .alert("錯誤", isPresented: $showingError) {
                Button("確定") { }
            } message: {
                Text(errorMessage)
            }
        }
    }
    
    private func formatDate(_ date: Date, isAllDay: Bool) -> String {
        let formatter = DateFormatter()
        if isAllDay {
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
        } else {
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
        }
        return formatter.string(from: date)
    }
    
    private func deleteEvent() {
        do {
            try calendarService.deleteEvent(eventId: event.id)
            presentationMode.wrappedValue.dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }
}

// MARK: - 詳情行視圖
struct DetailRow: View {
    let title: String
    let value: String
    
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - 編輯事件視圖
struct EditEventView: View {
    let event: CalendarEvent
    @ObservedObject var calendarService: CalendarService
    @Environment(\.presentationMode) var presentationMode
    
    @State private var title: String
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var notes: String
    @State private var location: String
    @State private var showingError = false
    @State private var errorMessage = ""
    
    init(event: CalendarEvent, calendarService: CalendarService) {
        self.event = event
        self.calendarService = calendarService
        self._title = State(initialValue: event.title)
        self._startDate = State(initialValue: event.startDate)
        self._endDate = State(initialValue: event.endDate)
        self._notes = State(initialValue: event.notes ?? "")
        self._location = State(initialValue: event.location ?? "")
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section("事件詳情") {
                    TextField("標題", text: $title)
                    
                    DatePicker("開始時間", selection: $startDate, displayedComponents: event.isAllDay ? [.date] : [.date, .hourAndMinute])
                    
                    DatePicker("結束時間", selection: $endDate, displayedComponents: event.isAllDay ? [.date] : [.date, .hourAndMinute])
                    
                    TextField("地點（選填）", text: $location)
                    
                    TextField("備註（選填）", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("編輯事件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("儲存") {
                        saveChanges()
                    }
                    .disabled(title.isEmpty)
                }
            }
            .alert("錯誤", isPresented: $showingError) {
                Button("確定") { }
            } message: {
                Text(errorMessage)
            }
        }
    }
    
    private func saveChanges() {
        do {
            try calendarService.updateEvent(
                eventId: event.id,
                title: title,
                startDate: startDate,
                endDate: endDate,
                notes: notes.isEmpty ? nil : notes,
                location: location.isEmpty ? nil : location
            )
            presentationMode.wrappedValue.dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }
}

// MARK: - API 設定視圖
struct APISettingsView: View {
    @ObservedObject var apiSettingsManager: APISettingsManager
    @Environment(\.presentationMode) var presentationMode
    @State private var tempAPIKey: String = ""
    @State private var showingDeleteConfirmation = false
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Gemini API 設定")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("API Key")
                            .font(.headline)
                        
                        SecureField("請輸入您的 Gemini API Key", text: $tempAPIKey)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        
                        if apiSettingsManager.isAPIConfigured {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("API Key 已設定")
                                    .foregroundColor(.green)
                                    .font(.caption)
                            }
                        }
                        
                        Text("您可以從 Google AI Studio 獲取免費的 API Key")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                }
                
                Section(header: Text("使用說明")) {
                    VStack(alignment: .leading, spacing: 8) {
                        InfoRow(icon: "1.circle.fill", title: "獲取 API Key", description: "前往 Google AI Studio 註冊並獲取免費的 API Key")
                        InfoRow(icon: "2.circle.fill", title: "輸入 API Key", description: "將獲取的 API Key 貼上到上方欄位中")
                        InfoRow(icon: "3.circle.fill", title: "開始使用", description: "設定完成後即可使用智能訊息分析功能")
                    }
                }
                
                if apiSettingsManager.isAPIConfigured {
                    Section {
                        Button(action: {
                            showingDeleteConfirmation = true
                        }) {
                            HStack {
                                Image(systemName: "trash")
                                Text("清除 API Key")
                            }
                            .foregroundColor(.red)
                        }
                    }
                }
            }
            .navigationTitle("API 設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("儲存") {
                        apiSettingsManager.saveAPIKey(tempAPIKey)
                        presentationMode.wrappedValue.dismiss()
                    }
                    .disabled(tempAPIKey.isEmpty)
                }
            }
            .alert("確認刪除", isPresented: $showingDeleteConfirmation) {
                Button("取消", role: .cancel) { }
                Button("刪除", role: .destructive) {
                    apiSettingsManager.clearAPIKey()
                    tempAPIKey = ""
                }
            } message: {
                Text("確定要清除已儲存的 API Key 嗎？")
            }
        }
        .onAppear {
            tempAPIKey = apiSettingsManager.apiKey
        }
    }
}

// MARK: - 資訊行視圖
struct InfoRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
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

#Preview {
    ContentView()
}
