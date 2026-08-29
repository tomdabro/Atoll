/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Defaults
import Foundation
import Security

/// Standalone Google Calendar integration, independent of CalendarManager's
/// EventKit-driven authorization state machine (Google has no EKAuthorizationStatus
/// equivalent). CalendarManager pulls this manager's calendars/events in
/// directly and merges them alongside whatever EventKit exposes, so all of
/// Atoll's existing calendar UI (notch, lock screen, Settings picker) shows
/// Google events for free once connected.
///
/// Coordinates GoogleCalendarOAuthService (auth) and GoogleCalendarAPI
/// (calls), and publishes raw state; the settings view owns all user-facing
/// wording.
@MainActor
final class GoogleCalendarManager: ObservableObject {
    static let shared = GoogleCalendarManager()

    @Published private(set) var isAuthenticated = false
    @Published private(set) var isAuthorizing = false
    @Published private(set) var error: GoogleCalendarError?

    private let tokenStore: GoogleCalendarTokenStoring
    private let oauth: GoogleCalendarOAuthService
    private let api: GoogleCalendarAPI

    /// Populated by the most recent `fetchCalendars()`, so `fetchEvents`
    /// doesn't need to re-fetch the calendar list on every event refresh.
    private var calendarsByID: [String: CalendarModel] = [:]

    /// Use `.shared`. The injectable initializer exists for tests: a second
    /// live instance would race the first over Google's token pair.
    init(
        tokenStore: GoogleCalendarTokenStoring = KeychainGoogleCalendarTokenStore(),
        httpClient: GoogleCalendarHTTPClient = URLSessionGoogleCalendarHTTPClient()
    ) {
        self.tokenStore = tokenStore
        let oauth = GoogleCalendarOAuthService(tokenStore: tokenStore, httpClient: httpClient)
        self.oauth = oauth
        self.api = GoogleCalendarAPI(tokenProvider: oauth, httpClient: httpClient)

        oauth.onTokenStateChange = { [weak self] in self?.refreshAuthenticationState() }
        refreshAuthenticationState()
    }

    var configuredClientID: String {
        Defaults[.googleCalendarClientID].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The Client Secret lives in the Keychain (credential material, not a
    /// display value), read/written directly for the settings field's binding.
    var clientSecret: String {
        get { tokenStore.read(.clientSecret) ?? "" }
        set {
            if newValue.isEmpty {
                tokenStore.delete(.clientSecret)
            } else {
                tokenStore.write(newValue, account: .clientSecret)
            }
        }
    }

    // MARK: - Connect / Disconnect

    func connect() {
        error = nil
        let clientID = configuredClientID
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else {
            error = .missingClientID
            return
        }
        guard !secret.isEmpty else {
            error = .missingClientSecret
            return
        }

        isAuthorizing = true
        Task {
            do {
                try await oauth.authorize(clientID: clientID, clientSecret: secret)
                error = nil
            } catch GoogleCalendarError.canceled {
                // The user closed the browser tab, or never got to it; not an error.
            } catch let calendarError as GoogleCalendarError {
                error = calendarError
            } catch {
                self.error = .loopbackServerFailed(String(describing: error))
            }
            isAuthorizing = false
            refreshAuthenticationState()
        }
    }

    /// Google exposes a revocation endpoint, but calling it here would also
    /// revoke every other app the user granted with this refresh token under
    /// the same consent; deleting the local pair is the safe, scoped action.
    /// Users can revoke the app itself at myaccount.google.com/permissions.
    func disconnect() {
        oauth.clearTokens()
        calendarsByID = [:]
        error = nil
        refreshAuthenticationState()
    }

    // MARK: - Calendar data

    func fetchCalendars() async -> [CalendarModel] {
        guard isAuthenticated else { return [] }
        let calendars = await api.calendars()
        calendarsByID = Dictionary(uniqueKeysWithValues: calendars.map { ($0.id, $0) })
        return calendars
    }

    /// Empty `calendarIDs` means "all known Google calendars", matching how
    /// the EventKit-backed CalendarService treats an empty selection.
    func fetchEvents(from start: Date, to end: Date, calendarIDs: [String]) async -> [EventModel] {
        guard isAuthenticated else { return [] }
        let ids = calendarIDs.isEmpty
            ? Array(calendarsByID.keys)
            : calendarIDs.filter { calendarsByID[$0] != nil }
        guard !ids.isEmpty else { return [] }
        return await api.events(from: start, to: end, calendarIDs: ids, calendarsByID: calendarsByID)
    }

    // MARK: - State

    private func refreshAuthenticationState() {
        let hasRefreshToken = !(tokenStore.read(.refreshToken) ?? "").isEmpty
        isAuthenticated = hasRefreshToken && !configuredClientID.isEmpty
    }
}
