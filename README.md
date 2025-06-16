# IntelliNotify - AI 訊息管理系統

## 功能概述

IntelliNotify 是一個智能訊息管理系統，它能夠根據用戶的工作狀態和訊息內容，智能地決定訊息的優先級和通知時機。這個應用程式特別適合需要專注工作的專業人士，幫助他們在保持工作效率的同時，不會錯過重要的訊息。

## 主要功能

### 1. AI訊息分析
- 使用 Gemini AI 分析訊息內容
- 自動判斷訊息優先級（緊急、重要、一般、低）
- 根據用戶當前工作狀態決定通知時機

### 2. 工作狀態追蹤
- 監控用戶當前使用的應用程式
- 追蹤螢幕使用時間
- 識別工作相關應用程式的使用情況

### 3. 自動化通知管理
- 即時通知：對於緊急訊息立即發送通知
- 延遲通知：根據工作狀態智能調整通知時機
- 自定義通知優先級

### 4. 訊息分類管理
- 處理中訊息列表
- 待處理訊息列表
- 清晰的訊息優先級標示

## 技術特點

### 1. 整合技術
- SwiftUI 框架
- UserNotifications 框架
- DeviceActivity 監控
- Gemini AI API 整合

### 2. 數據模型
- 訊息模型（Message）
- 用戶活動數據（UserActivityData）
- 工作狀態追蹤（WorkStatus）

### 3. 安全特性
- 通知權限管理
- 螢幕時間訪問控制
- 數據隱私保護

## 使用場景

1. **工作專注模式**
   - 自動判別工作時間
   - 過濾非緊急通知
   - 保持工作專注度

2. **休息時間管理**
   - 識別休息狀態
   - 適當放寬通知限制
   - 確保重要訊息及時接收

3. **緊急情況處理**
   - 緊急訊息立即通知
   - 重要訊息快速排程
   - 確保關鍵訊息不會遺漏

## 系統要求

- iOS 16.0 或更高版本
- 支援 iPhone 和 iPad
- 需要通知權限
- 需要行事曆存取權限
- 需要專注模式權限

## 隱私說明

- 僅在本地處理用戶活動數據
- 訊息內容通過 Gemini AI 進行分析
- 不存儲或分享用戶個人數據
- 所有權限使用都有明確說明

## 程式碼結構

### 主要檔案位置
- `ContentView.swift`: 主視圖和應用程式入口
  - 包含訊息列表顯示
  - 狀態卡片顯示
  - 新增訊息功能

### 功能開發
1. **訊息處理流程** 
```swift
func processIncomingMessage(_ message: Message) {
    let activityData = calendarService.getCurrentActivityData()
    
    geminiService.analyzeMessageAndWorkStatus(
        message: message,
        activityData: activityData
    ) { [weak self] result in
        // 處理分析結果
    }
}
```

2. **AI 分析訊息重要性** 
```swift
func analyzeMessageAndWorkStatus(
    message: Message,
    activityData: UserActivityData,
    completion: @escaping (Result<AnalysisResult, Error>) -> Void
) {
    // AI 分析邏輯
}
```

3. **通知管理**
```swift
private func sendImmediateNotification(message: Message, reasoning: String) {
    // 即時通知邏輯
}

private func scheduleDelayedNotification(message: Message) {
    // 延遲通知邏輯
}
```

### 重要功能介紹

#### 1. 行事曆整合
```swift
class CalendarService: ObservableObject {
    @Published var events: [CalendarEvent] = []
    @Published var currentWorkStatus: WorkStatus = .unknown
    
    func getCurrentActivityData() -> UserActivityData {
        // 獲取當前行事曆事件和工作狀態
    }
    
    private func updateWorkStatus() {
        // 根據行事曆事件更新工作狀態
    }
}
```

#### 2. 智能工作狀態判斷
- 自動識別會議時間
- 追蹤工作相關事件
- 智能判斷休息時間
- 支援全天事件處理

#### 3. 訊息優先級管理
```swift
enum MessagePriority: String, Codable, CaseIterable {
    case urgent = "urgent"      // 緊急
    case important = "important" // 重要
    case normal = "normal"      // 一般
    case low = "low"           // 低優先級
    case unknown = "unknown"    // 未知
}
```

#### 4. 專注模式整合
```swift
class FocusStatusService: ObservableObject {
    @Published var isFocused: Bool = false
    @Published var authorizationStatus: INFocusStatusAuthorizationStatus = .notDetermined
    
    func requestAuthorization() {
        // 請求專注模式權限
    }
    
    func observeFocusChanges() {
        // 監聽專注模式變化
    }
}
```

#### 5. 智能通知策略
- 根據工作狀態自動調整通知時機
- 支援批量處理低優先級訊息
- 會議期間智能延遲通知
- 專注模式下特殊處理

#### 6. 行事曆事件管理
- 支援新增、編輯、刪除事件
- 自動識別工作相關事件
- 智能分析會議時間
- 提供事件摘要視圖

#### 7. API 整合
- Gemini AI 智能分析
- 可配置的 API 設定
- 安全的 API Key 管理
- 錯誤處理機制

##聯繫方式
如有任何問題，請聯繫：[rayc57429@gmail.com]

