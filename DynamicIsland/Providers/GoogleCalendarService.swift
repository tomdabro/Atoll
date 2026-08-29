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

import AppKit
import Foundation

/// Read-only Google Calendar API v3 access: calendarList + per-calendar
/// events, scoped to `calendar.readonly` (Atoll never writes to Google
/// Calendar). Deliberately not a `CalendarServiceProviding` conformance --
/// that protocol's `requestAccess(to: EKEntityType)` and reminder-completion
/// methods are EventKit concepts with no Google equivalent. GoogleCalendarManager
/// merges this service's results directly into CalendarManager instead.
final class GoogleCalendarAPI {
    private static let baseURL = "https://www.googleapis.com/calendar/v3"

    private let tokenProvider: GoogleCalendarTokenProviding
    private let httpClient: GoogleCalendarHTTPClient

    init(tokenProvider: GoogleCalendarTokenProviding, httpClient: GoogleCalendarHTTPClient) {
        self.tokenProvider = tokenProvider
        self.httpClient = httpClient
    }

    func calendars() async -> [CalendarModel] {
        guard let data = await request(path: "/users/me/calendarList?minAccessRole=reader&maxResults=250") else {
            return []
        }
        guard let decoded = try? JSONDecoder().decode(GoogleCalendarListResponse.self, from: data) else {
            return []
        }
        return decoded.items.map { CalendarModel(from: $0) }
    }

    /// `calendarsByID` supplies the already-resolved `CalendarModel` for each
    /// requested id (from a prior `calendars()` call), so this doesn't have
    /// to re-fetch the calendar list on every event refresh.
    func events(
        from start: Date,
        to end: Date,
        calendarIDs: [String],
        calendarsByID: [String: CalendarModel]
    ) async -> [EventModel] {
        guard !calendarIDs.isEmpty else { return [] }

        let formatter = ISO8601DateFormatter()
        let timeMin = formatter.string(from: start)
        let timeMax = formatter.string(from: end)

        return await withTaskGroup(of: [EventModel].self) { group in
            for id in calendarIDs {
                guard let calendarModel = calendarsByID[id] else { continue }
                group.addTask { [weak self] in
                    await self?.events(calendarID: id, calendarModel: calendarModel, timeMin: timeMin, timeMax: timeMax) ?? []
                }
            }
            var all: [EventModel] = []
            for await events in group {
                all.append(contentsOf: events)
            }
            return all.sorted { $0.start < $1.start }
        }
    }

    private func events(
        calendarID: String,
        calendarModel: CalendarModel,
        timeMin: String,
        timeMax: String
    ) async -> [EventModel] {
        guard let encodedID = calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return [] }
        let path = "/calendars/\(encodedID)/events"
            + "?singleEvents=true&orderBy=startTime&maxResults=250"
            + "&timeMin=\(timeMin)&timeMax=\(timeMax)"
        guard let data = await request(path: path) else { return [] }
        guard let decoded = try? JSONDecoder().decode(GoogleEventListResponse.self, from: data) else { return [] }
        return decoded.items.compactMap { EventModel(from: $0, calendar: calendarModel) }
    }

    /// A 401 retries once against a force-refreshed token; any other failure
    /// (including a second 401) returns nil rather than throwing, matching
    /// the rest of the app's "unavailable reads as empty" calendar behavior.
    private func request(path: String, allowUnauthorizedRetry: Bool = true) async -> Data? {
        guard let token = await tokenProvider.validAccessToken(forceRefresh: false),
              let url = URL(string: Self.baseURL + path)
        else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        guard let (data, response) = try? await httpClient.data(for: request) else { return nil }

        if response.statusCode == 401, allowUnauthorizedRetry {
            guard let refreshedToken = await tokenProvider.validAccessToken(forceRefresh: true) else { return nil }
            var retryRequest = URLRequest(url: url)
            retryRequest.setValue("Bearer \(refreshedToken)", forHTTPHeaderField: "Authorization")
            guard let (retryData, retryResponse) = try? await httpClient.data(for: retryRequest),
                  (200..<300).contains(retryResponse.statusCode)
            else { return nil }
            return retryData
        }

        guard (200..<300).contains(response.statusCode) else { return nil }
        return data
    }
}

// MARK: - REST DTOs

struct GoogleCalendarListItem: Decodable {
    let id: String
    let summary: String?
    let backgroundColor: String?
    let primary: Bool?
}

struct GoogleCalendarListResponse: Decodable {
    let items: [GoogleCalendarListItem]
}

struct GoogleEventDateTime: Decodable {
    let date: String?
    let dateTime: String?
    let timeZone: String?
}

struct GoogleEventAttendee: Decodable {
    let email: String?
    let displayName: String?
    let responseStatus: String?
    let organizer: Bool?
    let isSelf: Bool?

    enum CodingKeys: String, CodingKey {
        case email, displayName, responseStatus, organizer
        case isSelf = "self"
    }
}

struct GoogleConferenceEntryPoint: Decodable {
    let entryPointType: String?
    let uri: String?
}

struct GoogleConferenceData: Decodable {
    let entryPoints: [GoogleConferenceEntryPoint]?
}

struct GoogleCalendarEventItem: Decodable {
    let id: String
    let status: String?
    let summary: String?
    let description: String?
    let location: String?
    let htmlLink: String?
    let hangoutLink: String?
    let start: GoogleEventDateTime?
    let end: GoogleEventDateTime?
    let attendees: [GoogleEventAttendee]?
    let recurringEventId: String?
    let conferenceData: GoogleConferenceData?
}

struct GoogleEventListResponse: Decodable {
    let items: [GoogleCalendarEventItem]
}

// MARK: - Model Mapping

extension CalendarModel {
    init(from item: GoogleCalendarListItem) {
        self.init(
            accountName: "Google Calendar",
            id: item.id,
            title: item.summary ?? item.id,
            color: NSColor(googleHex: item.backgroundColor) ?? .systemBlue,
            isSubscribed: item.primary != true,
            isReminder: false
        )
    }
}

extension EventModel {
    init?(from item: GoogleCalendarEventItem, calendar: CalendarModel) {
        // Cancelled instances of a recurring event still appear in the feed; skip them.
        guard item.status != "cancelled" else { return nil }

        let (start, startIsAllDay) = Self.googleDate(from: item.start)
        let (end, _) = Self.googleDate(from: item.end)
        guard let start, let end else { return nil }

        let attendees = item.attendees ?? []
        let participants = attendees.map { attendee in
            Participant(
                name: attendee.displayName ?? attendee.email ?? "",
                status: AttendanceStatus(googleResponseStatus: attendee.responseStatus),
                isOrganizer: attendee.organizer == true,
                isCurrentUser: attendee.isSelf == true
            )
        }
        let selfResponseStatus = attendees.first(where: { $0.isSelf == true })?.responseStatus

        self.init(
            id: "google:\(calendar.id):\(item.id)",
            start: start,
            end: end,
            title: item.summary ?? "",
            location: item.location,
            notes: item.description,
            url: item.htmlLink.flatMap(URL.init(string:)),
            isAllDay: startIsAllDay,
            type: .event(AttendanceStatus(googleResponseStatus: selfResponseStatus)),
            calendar: calendar,
            participants: participants,
            timeZone: item.start?.timeZone.flatMap(TimeZone.init(identifier:)),
            hasRecurrenceRules: item.recurringEventId != nil,
            priority: nil,
            conferenceURL: Self.googleConferenceURL(from: item)
        )
    }

    private static func googleDate(from dt: GoogleEventDateTime?) -> (Date?, Bool) {
        guard let dt else { return (nil, false) }
        if let dateTimeString = dt.dateTime {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: dateTimeString) { return (date, false) }
            formatter.formatOptions = [.withInternetDateTime]
            return (formatter.date(from: dateTimeString), false)
        }
        if let dateString = dt.date {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone(identifier: "UTC")
            return (formatter.date(from: dateString), true)
        }
        return (nil, false)
    }

    private static func googleConferenceURL(from item: GoogleCalendarEventItem) -> URL? {
        if let hangout = item.hangoutLink, let url = URL(string: hangout) { return url }
        guard let entryPoints = item.conferenceData?.entryPoints else { return nil }
        let video = entryPoints.first { $0.entryPointType == "video" } ?? entryPoints.first
        return video?.uri.flatMap(URL.init(string:))
    }
}

extension AttendanceStatus {
    init(googleResponseStatus: String?) {
        switch googleResponseStatus {
        case "accepted": self = .accepted
        case "tentative": self = .maybe
        case "declined": self = .declined
        case "needsAction": self = .pending
        default:
            // No attendees, or not listed as one -- this is the owner's own
            // unshared event, which reads as a normal confirmed entry.
            self = .accepted
        }
    }
}

private extension NSColor {
    convenience init?(googleHex hex: String?) {
        guard var hex = hex?.trimmingCharacters(in: .whitespacesAndNewlines),
              hex.hasPrefix("#"), hex.count == 7
        else { return nil }
        hex.removeFirst()
        guard let value = UInt32(hex, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
