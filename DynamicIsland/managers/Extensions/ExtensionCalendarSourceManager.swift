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

/// A third-party calendar source registered over AtollRPC (see
/// `ExtensionRPCService.handleRegisterCalendarSource`). AtollPluginManager is
/// the only client that speaks this today, doing Google Calendar OAuth and
/// polling natively rather than relaying an external plugin process (there's
/// no independently-useful standalone "Google Calendar" program to relay,
/// unlike cliamp for media) -- `sourceID` is whatever the broker picked
/// (e.g. "google-calendar") and is unique across every registered source.
struct ExtensionCalendarSourceDescriptor: Equatable {
    let sourceID: String
    let bundleIdentifier: String
    let name: String
    let accountLabel: String?
}

/// Wire payload for one calendar, published via `atoll.publishCalendarState`.
/// Field names are load-bearing: AtollPluginManager's `CalendarSourceCalendarPayload`
/// must match exactly, since there's no shared package between the two repos.
struct CalendarSourceCalendarPayload: Codable, Equatable {
    let id: String
    let title: String
    let colorHex: String
    let isSubscribed: Bool
}

/// Wire payload for one event participant.
struct CalendarSourceParticipantPayload: Codable, Equatable {
    let name: String
    let status: String
    let isOrganizer: Bool
    let isCurrentUser: Bool
}

/// Wire payload for one event, published via `atoll.publishCalendarState`.
struct CalendarSourceEventPayload: Codable, Equatable {
    let id: String
    let calendarID: String
    let title: String
    let start: String
    let end: String
    let isAllDay: Bool
    let location: String?
    let notes: String?
    let url: String?
    let attendanceStatus: String?
    let participants: [CalendarSourceParticipantPayload]
    let timeZoneIdentifier: String?
    let hasRecurrenceRules: Bool
    let conferenceURL: String?
}

/// Tracks third-party calendar sources registered over AtollRPC and their
/// latest published calendars/events, and exposes a merged, provider-agnostic
/// view that `CalendarManager` folds in alongside EventKit's own results.
/// Mirrors `ExtensionMediaSourceManager` in shape.
///
/// Deliberately push-based, not pull: the registered source (the broker)
/// polls its own upstream (Google's API) on its own schedule and pushes a
/// snapshot; `CalendarManager` reads whatever was last published
/// synchronously, no network calls of its own for third-party calendars.
final class ExtensionCalendarSourceManager: ObservableObject {
    static let shared = ExtensionCalendarSourceManager()

    @Published private(set) var sources: [String: ExtensionCalendarSourceDescriptor] = [:]
    @Published private(set) var calendarsBySource: [String: [CalendarSourceCalendarPayload]] = [:]
    @Published private(set) var eventsBySource: [String: [CalendarSourceEventPayload]] = [:]

    private init() {}

    // MARK: - Registration

    func register(_ descriptor: ExtensionCalendarSourceDescriptor) {
        sources[descriptor.sourceID] = descriptor
    }

    func unregister(sourceID: String, bundleIdentifier: String) {
        guard sources[sourceID]?.bundleIdentifier == bundleIdentifier else { return }
        sources.removeValue(forKey: sourceID)
        calendarsBySource.removeValue(forKey: sourceID)
        eventsBySource.removeValue(forKey: sourceID)
    }

    /// Drops every source owned by a connection that just disconnected, so
    /// nothing goes stale in the calendar list.
    func unregisterAll(forBundleIdentifier bundleIdentifier: String) {
        for sourceID in sources.filter({ $0.value.bundleIdentifier == bundleIdentifier }).keys {
            sources.removeValue(forKey: sourceID)
            calendarsBySource.removeValue(forKey: sourceID)
            eventsBySource.removeValue(forKey: sourceID)
        }
    }

    func owner(of sourceID: String) -> String? {
        sources[sourceID]?.bundleIdentifier
    }

    func updateState(sourceID: String, calendars: [CalendarSourceCalendarPayload], events: [CalendarSourceEventPayload]) {
        guard sources[sourceID] != nil else { return }
        calendarsBySource[sourceID] = calendars
        eventsBySource[sourceID] = events
    }

    // MARK: - Merged view for CalendarManager

    /// All calendars across every registered source, mapped to the app's
    /// provider-agnostic `CalendarModel` -- the same struct EventKit
    /// produces, so existing calendar UI (notch, lock screen, per-calendar
    /// toggles) needs no changes to also show these.
    var allCalendars: [CalendarModel] {
        sources.values.flatMap { source in
            (calendarsBySource[source.sourceID] ?? []).map { CalendarModel(from: $0, accountName: source.name) }
        }
    }

    /// Events across every registered source overlapping `start..<end`,
    /// restricted to `calendarIDs` (empty = every known calendar, matching
    /// the EventKit-backed `CalendarService`'s empty-selection convention).
    func events(from start: Date, to end: Date, calendarIDs: Set<String>) -> [EventModel] {
        var result: [EventModel] = []
        for source in sources.values {
            let calendars = calendarsBySource[source.sourceID] ?? []
            let calendarModelsByID = Dictionary(uniqueKeysWithValues: calendars.map { ($0.id, CalendarModel(from: $0, accountName: source.name)) })
            for payload in eventsBySource[source.sourceID] ?? [] {
                guard calendarIDs.isEmpty || calendarIDs.contains(payload.calendarID) else { continue }
                guard let calendarModel = calendarModelsByID[payload.calendarID] else { continue }
                guard let event = EventModel(from: payload, calendar: calendarModel) else { continue }
                guard event.start < end, event.end > start else { continue }
                result.append(event)
            }
        }
        return result.sorted { $0.start < $1.start }
    }
}

// MARK: - Model Mapping

extension CalendarModel {
    init(from payload: CalendarSourceCalendarPayload, accountName: String) {
        self.init(
            accountName: accountName,
            id: payload.id,
            title: payload.title,
            color: NSColor(calendarSourceHex: payload.colorHex) ?? .systemBlue,
            isSubscribed: payload.isSubscribed,
            isReminder: false
        )
    }
}

extension EventModel {
    init?(from payload: CalendarSourceEventPayload, calendar: CalendarModel) {
        guard let start = Self.parseCalendarSourceDate(payload.start),
              let end = Self.parseCalendarSourceDate(payload.end)
        else { return nil }

        let participants = payload.participants.map { p in
            Participant(
                name: p.name,
                status: AttendanceStatus(calendarSourceStatus: p.status),
                isOrganizer: p.isOrganizer,
                isCurrentUser: p.isCurrentUser
            )
        }

        self.init(
            id: "\(calendar.id):\(payload.id)",
            start: start,
            end: end,
            title: payload.title,
            location: payload.location,
            notes: payload.notes,
            url: payload.url.flatMap(URL.init(string:)),
            isAllDay: payload.isAllDay,
            type: .event(AttendanceStatus(calendarSourceStatus: payload.attendanceStatus)),
            calendar: calendar,
            participants: participants,
            timeZone: payload.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)),
            hasRecurrenceRules: payload.hasRecurrenceRules,
            priority: nil,
            conferenceURL: payload.conferenceURL.flatMap(URL.init(string:))
        )
    }

    private static func parseCalendarSourceDate(_ raw: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: raw) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: raw) { return date }

        // All-day events arrive as a bare "yyyy-MM-dd".
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = TimeZone(identifier: "UTC")
        return dayFormatter.date(from: raw)
    }
}

private extension AttendanceStatus {
    init(calendarSourceStatus: String?) {
        switch calendarSourceStatus {
        case "accepted": self = .accepted
        case "maybe": self = .maybe
        case "declined": self = .declined
        case "pending": self = .pending
        default:
            // No attendees / not listed as one -- the owner's own unshared
            // event, which reads as a normal confirmed entry.
            self = .accepted
        }
    }
}

private extension NSColor {
    convenience init?(calendarSourceHex hex: String) {
        var hex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.hasPrefix("#"), hex.count == 7 else { return nil }
        hex.removeFirst()
        guard let value = UInt32(hex, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
