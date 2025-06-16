import SwiftUI
import Foundation
import UserNotifications
import Combine
import EventKit
import Intents

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

// Gemini API 相關結構
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

struct DelayedNotification: Identifiable {
    let id = UUID()
    let message: Message
    let scheduledTime: Date
    let reason: String
}

struct NotificationSettings {
    var enableSmartDelay: Bool = true
    var respectFocusMode: Bool = true
    var workHoursStart: Int = 9
    var workHoursEnd: Int = 18
    var allowUrgentDuringFocus: Bool = true
    var batchLowPriorityMessages: Bool = true
}

enum NotificationDelayStrategy {
    case immediate
    case delayUntilFree
    case delayUntilEndOfMeeting
    case batchAtEndOfDay
    case suppress
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

// MARK: - Focus 狀態管理服務
class FocusStatusService: ObservableObject {
    @Published var isFocused: Bool = false
    @Published var authorizationStatus: INFocusStatusAuthorizationStatus = .notDetermined
    @Published var isAuthorized: Bool = false
    
    init() {
        checkAuthorizationStatus()
    }
    
    func checkAuthorizationStatus() {
        authorizationStatus = INFocusStatusCenter.default.authorizationStatus
        isAuthorized = authorizationStatus == .authorized
        
        if isAuthorized {
            updateFocusStatus()
        }
    }
    
    func requestAuthorization() {
        INFocusStatusCenter.default.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                self?.authorizationStatus = status
                self?.isAuthorized = status == .authorized
                
                if self?.isAuthorized == true {
                    self?.updateFocusStatus()
                }
            }
        }
    }
    
    private func updateFocusStatus() {
        guard isAuthorized else { return }
        isFocused = INFocusStatusCenter.default.focusStatus.isFocused ?? false
    }
    
    func observeFocusChanges() {
        Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.updateFocusStatus()
        }
    }
}

// MARK: - 行事曆服務
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
        print("開始請求行事曆權限...")
        
        eventStore.requestAccess(to: .event) { [weak self] granted, error in
            print("權限請求結果: granted=\(granted), error=\(String(describing: error))")
            
            DispatchQueue.main.async {
                self?.authorizationStatus = EKEventStore.authorizationStatus(for: .event)
                self?.isAuthorized = granted
                
                if granted {
                    print("行事曆權限已授予，開始載入事件")
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
            let hasWorkEvent = currentEvents.contains { event in
                isWorkRelatedEvent(event)
            }
            
            currentWorkStatus = hasWorkEvent ? .working : .inMeeting
        } else {
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
        loadEvents()
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
        loadEvents()
    }
    
    func deleteEvent(eventId: String) throws {
        guard isAuthorized else {
            throw NSError(domain: "Calendar", code: 1, userInfo: [NSLocalizedDescriptionKey: "沒有行事曆權限"])
        }
        
        guard let event = eventStore.event(withIdentifier: eventId) else {
            throw NSError(domain: "Calendar", code: 2, userInfo: [NSLocalizedDescriptionKey: "找不到指定的事件"])
        }
        
        try eventStore.remove(event, span: .thisEvent)
        loadEvents()
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

// MARK: - 智能通知管理服務
class SmartNotificationService: ObservableObject {
    @Published var pendingNotifications: [DelayedNotification] = []
    @Published var notificationSettings = NotificationSettings()
    
    private let focusService = FocusStatusService()
    private let calendarService = CalendarService()
    
    func scheduleSmartNotification(
        for message: Message,
        priority: MessagePriority,
        currentContext: UserActivityData
    ) {
        let delayStrategy = determineDelayStrategy(
            priority: priority,
            isFocused: focusService.isFocused,
            workStatus: currentContext.workStatus
        )
        
        switch delayStrategy {
        case .immediate:
            sendImmediateNotification(message: message, priority: priority)
            
        case .delayUntilFree:
            scheduleDelayedNotification(
                message: message,
                delay: calculateOptimalDelay(currentContext: currentContext),
                reason: "等待空閒時間通知"
            )
            
        case .delayUntilEndOfMeeting:
            if let nextFreeTime = findNextFreeTime() {
                scheduleDelayedNotification(
                    message: message,
                    delay: nextFreeTime.timeIntervalSinceNow,
                    reason: "會議結束後通知"
                )
            } else {
                scheduleDelayedNotification(
                    message: message,
                    delay: 30 * 60,
                    reason: "稍後通知"
                )
            }
            
        case .batchAtEndOfDay:
            addToBatchNotification(message: message)
            
        case .suppress:
            break
        }
    }
    
    private func determineDelayStrategy(
        priority: MessagePriority,
        isFocused: Bool,
        workStatus: WorkStatus
    ) -> NotificationDelayStrategy {
        if priority == .urgent {
            return .immediate
        }
        
        if isFocused {
            switch priority {
            case .urgent:
                return .immediate
            case .important:
                return workStatus == .inMeeting ? .delayUntilEndOfMeeting : .delayUntilFree
            case .normal:
                return .delayUntilFree
            case .low:
                return .batchAtEndOfDay
            case .unknown:
                return .suppress
            }
        }
        
        if workStatus == .inMeeting {
            switch priority {
            case .urgent:
                return .immediate
            case .important:
                return .delayUntilEndOfMeeting
            case .normal, .low:
                return .delayUntilFree
            case .unknown:
                return .suppress
            }
        }
        
        return .immediate
    }
    
    private func calculateOptimalDelay(currentContext: UserActivityData) -> TimeInterval {
        switch currentContext.workStatus {
        case .working:
            return 15 * 60
        case .inMeeting:
            return findNextFreeTime()?.timeIntervalSinceNow ?? 30 * 60
        case .resting:
            return 5 * 60
        case .free:
            return 0
        case .unknown:
            return 0
        }
    }
    
    private func findNextFreeTime() -> Date? {
        let now = Date()
        let calendar = Calendar.current
        
        let upcomingEvents = calendarService.events.filter { $0.startDate > now }
            .sorted { $0.startDate < $1.startDate }
        
        for event in upcomingEvents {
            if event.startDate.timeIntervalSinceNow > 5 * 60 {
                return event.startDate
            }
        }
        
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: calendar.date(byAdding: .day, value: 1, to: now)!)
    }
    
    private func sendImmediateNotification(message: Message, priority: MessagePriority) {
        let content = UNMutableNotificationContent()
        content.title = "即時訊息 - \(message.sender)"
        content.body = message.content
        content.sound = priority == .urgent ? .defaultCritical : .default
        
        let request = UNNotificationRequest(
            identifier: "immediate_\(message.id.uuidString)",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    private func scheduleDelayedNotification(message: Message, delay: TimeInterval, reason: String) {
        let delayedNotification = DelayedNotification(
            message: message,
            scheduledTime: Date().addingTimeInterval(delay),
            reason: reason
        )
        
        pendingNotifications.append(delayedNotification)
        
        let content = UNMutableNotificationContent()
        content.title = "延遲訊息 - \(message.sender)"
        content.body = message.content
        content.sound = .default
        content.userInfo = ["reason": reason]
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        let request = UNNotificationRequest(
            identifier: "delayed_\(message.id.uuidString)",
            content: content,
            trigger: trigger
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    private func addToBatchNotification(message: Message) {
        let delayedNotification = DelayedNotification(
            message: message,
            scheduledTime: endOfDay(),
            reason: "日終摘要"
        )
        
        pendingNotifications.append(delayedNotification)
    }
    
    private func endOfDay() -> Date {
        let calendar = Calendar.current
        return calendar.date(bySettingHour: 18, minute: 0, second: 0, of: Date()) ?? Date()
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
    private let smartNotificationService = SmartNotificationService()
    
    func processIncomingMessage(_ message: Message) {
        let activityData = calendarService.getCurrentActivityData()
        
        geminiService.analyzeMessageAndWorkStatus(
            message: message,
            activityData: activityData
        ) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let analysis):
                    self?.handleAnalysisResult(message: message, analysis: analysis, activityData: activityData)
                case .failure(let error):
                    print("分析失敗: \(error)")
                    self?.handleDefaultMessage(message, activityData: activityData)
                }
            }
        }
    }
    
    private func handleAnalysisResult(message: Message, analysis: AnalysisResult, activityData: UserActivityData) {
        var updatedMessage = message
        updatedMessage.priority = MessagePriority(rawValue: analysis.messagePriority) ?? .normal
        updatedMessage.isProcessed = true
        
        messages.append(updatedMessage)
        
        smartNotificationService.scheduleSmartNotification(
            for: updatedMessage,
            priority: updatedMessage.priority,
            currentContext: activityData
        )
    }
    
    private func handleDefaultMessage(_ message: Message, activityData: UserActivityData) {
        var updatedMessage = message
        updatedMessage.priority = .normal
        updatedMessage.isProcessed = true
        messages.append(updatedMessage)
        
        smartNotificationService.scheduleSmartNotification(
            for: updatedMessage,
            priority: .normal,
            currentContext: activityData
        )
    }
}

// MARK: - Focus 權限橫幅
struct FocusPermissionBanner: View {
    @ObservedObject var focusService: FocusStatusService
    
    var body: some View {
        HStack {
            Image(systemName: "moon.circle")
                .foregroundColor(.purple)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("需要專注模式權限")
                    .font(.headline)
                    .foregroundColor(.primary)
                Text("允許存取專注狀態以提供智能通知延遲")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button("授權") {
                focusService.requestAuthorization()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding()
        .background(Color.purple.opacity(0.1))
        .cornerRadius(12)
        .padding(.horizontal)
    }
}

// MARK: - 智能狀態卡片視圖
struct SmartStatusCard: View {
    @ObservedObject var calendarService: CalendarService
    @ObservedObject var focusService: FocusStatusService
    
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading) {
                    Text("當前狀態")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack {
                        Text(calendarService.currentWorkStatus.displayName)
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        if focusService.isFocused {
                            Image(systemName: "moon.fill")
                                .foregroundColor(.purple)
                                .font(.caption)
                        }
                    }
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
            
            HStack {
                VStack(alignment: .leading) {
                    Text("通知策略")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(getNotificationStrategy())
                        .font(.subheadline)
                        .foregroundColor(.primary)
                }
                Spacer()
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
    
    private func getNotificationStrategy() -> String {
        if focusService.isFocused {
            return "專注模式：智能延遲"
        }
        
        switch calendarService.currentWorkStatus {
        case .working:
            return "工作中：重要訊息延遲"
        case .inMeeting:
            return "會議中：會後通知"
        case .resting:
            return "休息中：短暫延遲"
        case .free:
            return "空閒：即時通知"
        case .unknown:
            return "標準模式"
        }
    }
}

// MARK: - 通知設定視圖
struct NotificationSettingsView: View {
    @Environment(\.presentationMode) var presentationMode
    @State private var settings = NotificationSettings()
    
    var body: some View {
        NavigationView {
            Form {
                Section("智能延遲設定") {
                    Toggle("啟用智能延遲", isOn: $settings.enableSmartDelay)
                    Toggle("尊重專注模式", isOn: $settings.respectFocusMode)
                    Toggle("專注時允許緊急訊息", isOn: $settings.allowUrgentDuringFocus)
                        .disabled(!settings.respectFocusMode)
                }
                
                Section("工作時間設定") {
                    HStack {
                        Text("開始時間")
                        Spacer()
                        Picker("開始時間", selection: $settings.workHoursStart) {
                            ForEach(0..<24, id: \.self) { hour in
                                Text("\(hour):00").tag(hour)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(width: 100, height: 100)
                    }
                    
                    HStack {
                        Text("結束時間")
                        Spacer()
                        Picker("結束時間", selection: $settings.workHoursEnd) {
                            ForEach(0..<24, id: \.self) { hour in
                                Text("\(hour):00").tag(hour)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(width: 100, height: 100)
                    }
                }
                
                Section("批量通知") {
                    Toggle("低優先級訊息批量處理", isOn: $settings.batchLowPriorityMessages)
                    
                    if settings.batchLowPriorityMessages {
                        Text("低優先級訊息將在工作時間結束時統一發送摘要")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Section("說明") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("智能延遲功能")
                            .font(.headline)
                        Text("• 緊急訊息：無論何時都會立即通知")
                            .font(.caption)
                        Text("• 重要訊息：根據當前狀態智能延遲")
                            .font(.caption)
                        Text("• 一般訊息：在空閒時間通知")
                            .font(.caption)
                        Text("• 低優先級：批量處理或延遲到工作時間結束")
                            .font(.caption)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("通知設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
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
                
                Text("狀態: \(authorizationStatusText)")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            
            Spacer()
            
            Button("授權") {
                print("用戶點擊授權按鈕")
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
    
    private var authorizationStatusText: String {
        switch calendarService.authorizationStatus {
        case .notDetermined:
            return "未請求"
        case .restricted:
            return "受限制"
        case .denied:
            return "被拒絕"
        case .authorized:
            return "已授權"
        case .fullAccess:
            return "完全存取"
        case .writeOnly:
            return "僅寫入"
        @unknown default:
            return "未知"
        }
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
    @State private var endDate = Date().addingTimeInterval(3600)
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

// MARK: - 主要視圖
struct ContentView: View {
    @StateObject private var messageService = MessageService()
    @StateObject private var calendarService = CalendarService()
    @StateObject private var focusService = FocusStatusService()
    @State private var showingAddMessage = false
    @State private var showingAPISettings = false
    @State private var showingCalendarView = false
    @State private var showingNotificationSettings = false
    @State private var newMessageContent = ""
    @State private var newMessageSender = ""
    
    var body: some View {
        NavigationView {
            VStack {
                if !messageService.geminiService.apiSettingsManager.isAPIConfigured {
                    APIStatusBanner(showingAPISettings: $showingAPISettings)
                }
                
                if !calendarService.isAuthorized {
                    CalendarPermissionBanner(calendarService: calendarService)
                }
                
                if !focusService.isAuthorized {
                    FocusPermissionBanner(focusService: focusService)
                }
                
                SmartStatusCard(
                    calendarService: calendarService,
                    focusService: focusService
                )
                
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
            .navigationTitle("智能通知管理")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button(action: {
                        showingNotificationSettings = true
                    }) {
                        Image(systemName: "bell.badge")
                            .foregroundColor(.purple)
                    }
                    
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
            .sheet(isPresented: $showingNotificationSettings) {
                NotificationSettingsView()
            }
        }
        .onAppear {
            requestNotificationPermission()
            focusService.observeFocusChanges()
        }
    }
    
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound, .criticalAlert]) { granted, error in
            if granted {
                print("通知權限已授予")
            } else {
                print("通知權限被拒絕")
            }
        }
    }
}

#Preview {
    ContentView()
}
