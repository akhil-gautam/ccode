import AppKit
import SwiftUI
import UserNotifications
import CCodeCore

@MainActor protocol SessionNotificationDelivery: AnyObject {
    func deliver(_ notice: SessionNotice)
    func clear(sessionID: UUID)
    func requestAuthorization() async throws -> Bool
    func stopDelivery()
}
extension SessionNotificationDelivery {
    func requestAuthorization() async throws -> Bool { false }
    func stopDelivery() {}
}

struct SessionStatusFilters: View {
    @Bindable var store: AppStore
    var body: some View {
        HStack(spacing: 8) {
            Menu {
                SessionStatusFilterOptions(store: store)
            } label: {
                HStack(spacing: 5) {
                    Text(store.sessionStatusFilter?.title ?? "All sessions").font(SidebarTypography.font(12)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Filter sessions by status")
            Spacer(minLength: 0)
            if store.sessionStatusFilter != nil {
                Button { store.sessionStatusFilter = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }.help("Clear session filter")
            }
            Button { store.openSessionSearch() } label: { Image(systemName: "magnifyingglass").font(.system(size: 13)) }
                .help("Search all sessions (⌘K)").accessibilityLabel("Search all sessions")
        }.foregroundStyle(.secondary).buttonStyle(.plain).frame(height: 26)
    }
}

struct SessionStatusFilterOptions: View {
    @Bindable var store: AppStore
    var body: some View {
        Button("All sessions") { store.sessionStatusFilter = nil }
        Divider()
        ForEach(SessionActivity.allCases, id: \.self) { status in
            Button { store.sessionStatusFilter = status } label: {
                HStack {
                    Text(status.title)
                    if store.sessionStatusFilter == status { Image(systemName: "checkmark") }
                }
            }
        }
    }
}

extension AppStore {
    func enableSessionNotifications() async {
        do {
            guard try await attentionNotifications?.requestAuthorization() == true else {
                notificationStatus = "Allow ccode notifications in System Settings to receive alerts."
                return
            }
            settings.sessionNotifications = true; settings.save(); notificationStatus = "Notifications enabled"
        } catch { notificationStatus = "Could not enable notifications. Check System Settings." }
    }
}

/// Generic summaries only. The persisted receipt is checked again when the notification is opened.
@MainActor final class SessionNotificationCoordinator: NSObject, SessionNotificationDelivery, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    private weak var store: AppStore?
    private var deliveries: [UUID: (receipt: UUID, task: Task<Void, Never>)] = [:]
    private var pendingOpen: (session: UUID, receipt: UUID)?
    init(center: UNUserNotificationCenter = .current()) {
        self.center = center; super.init(); center.delegate = self
    }
    func attach(_ store: AppStore) {
        self.store = store; store.attentionNotifications = self
        if let pendingOpen { self.pendingOpen = nil; open(pendingOpen.session, receipt: pendingOpen.receipt) }
    }
    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }
    func deliver(_ notice: SessionNotice) {
        guard store?.settings.sessionNotifications == true else { return }
        deliveries[notice.sessionID]?.task.cancel()
        let identifier = Self.identifier(notice)
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if deliveries[notice.sessionID]?.receipt == notice.receipt.id { deliveries.removeValue(forKey: notice.sessionID) } }
            let settings = await center.notificationSettings()
            guard !Task.isCancelled, [.authorized, .provisional].contains(settings.authorizationStatus),
                  store?.settings.sessionNotifications == true,
                  store?.sessions.contains(where: { $0.id == notice.sessionID && !$0.archived && $0.attention?.id == notice.receipt.id }) == true,
                  store?.isSessionBeingViewed(notice.sessionID) == false else { return }
            let content = UNMutableNotificationContent()
            content.title = "ccode"; content.body = notice.body; content.sound = .default
            content.userInfo = ["session": notice.sessionID.uuidString, "receipt": notice.receipt.id.uuidString]
            do {
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
                if Task.isCancelled || store?.settings.sessionNotifications != true ||
                    store?.sessions.contains(where: { $0.id == notice.sessionID && !$0.archived && $0.attention?.id == notice.receipt.id }) != true ||
                    store?.isSessionBeingViewed(notice.sessionID) == true {
                    center.removeDeliveredNotifications(withIdentifiers: [identifier])
                }
            } catch { if !Task.isCancelled { store?.notificationStatus = "Session alert could not be delivered. Check System Settings." } }
        }
        deliveries[notice.sessionID] = (notice.receipt.id, task)
    }
    private static func identifier(_ notice: SessionNotice) -> String { prefix(notice.sessionID) + notice.receipt.id.uuidString }
    private static func prefix(_ id: UUID) -> String { "ccode.session." + id.uuidString + "." }
    func clear(sessionID: UUID) {
        deliveries.removeValue(forKey: sessionID)?.task.cancel()
        Task { [weak self, center] in
            let delivered = await center.deliveredNotifications()
            // A later receipt may already have been submitted while this lookup was suspended.
            let current = self?.store?.sessions.first { $0.id == sessionID && !$0.archived }?.attention
            let retained = current.map { Self.prefix(sessionID) + $0.id.uuidString }
            center.removeDeliveredNotifications(withIdentifiers: delivered.map(\.request.identifier).filter {
                $0.hasPrefix(Self.prefix(sessionID)) && $0 != retained
            })
        }
    }
    func stopDelivery() {
        for value in deliveries.values { value.task.cancel() }
        deliveries.removeAll()
    }
    private func open(_ session: UUID, receipt: UUID) {
        guard let store, !store.loading else { pendingOpen = (session, receipt); return }
        Task {
            if await store.openSessionNotification(sessionID: session, receiptID: receipt) {
                NSApp.activate(ignoringOtherApps: true)
                store.acknowledgeVisibleCompletions()
            }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let session = (response.notification.request.content.userInfo["session"] as? String).flatMap(UUID.init(uuidString:)),
           let receipt = (response.notification.request.content.userInfo["receipt"] as? String).flatMap(UUID.init(uuidString:)) {
            Task { @MainActor [weak self] in self?.open(session, receipt: receipt) }
        }
        completionHandler()
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        guard let session = (notification.request.content.userInfo["session"] as? String).flatMap(UUID.init(uuidString:)),
              let receipt = (notification.request.content.userInfo["receipt"] as? String).flatMap(UUID.init(uuidString:)) else { return [] }
        return await MainActor.run {
            guard let store = self.store, store.settings.sessionNotifications == true,
                  store.sessions.contains(where: { $0.id == session && !$0.archived && $0.attention?.id == receipt }),
                  !store.isSessionBeingViewed(session) else { return [] }
            return [.banner, .list, .sound]
        }
    }
}
