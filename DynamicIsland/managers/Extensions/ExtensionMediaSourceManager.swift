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

import Foundation
import Defaults

/// A third-party media source registered over AtollRPC (see
/// `ExtensionRPCService.handleRegisterMediaSource`). AtollPluginManager is the
/// only client that speaks this today; `sourceID` is whatever the plugin
/// picked (e.g. "cliamp") and is unique across every registered source.
struct ExtensionMediaSourceDescriptor: Equatable {
    let sourceID: String
    let bundleIdentifier: String
    let name: String
    let supportsSeek: Bool
    let supportsSkip: Bool
}

/// A Now Playing snapshot published for a registered source.
struct ExtensionMediaSourceNowPlaying: Equatable {
    let sourceID: String
    let title: String
    let artist: String
    let album: String
    /// Decoded from the RPC payload's base64 `artworkBase64` field, if present.
    let artworkData: Data?
    let isPlaying: Bool
    let elapsedTime: TimeInterval
    let duration: TimeInterval?
    let timestamp: Date
}

/// A playback command Atoll sends back to a registered source's owning
/// connection, in response to user interaction (notch controls, media keys).
enum ExtensionMediaCommand {
    case play
    case pause
    case togglePlayPause
    case nextTrack
    case previousTrack
    case seek(to: TimeInterval)

    var rpcCommandName: String {
        switch self {
        case .play: return "play"
        case .pause: return "pause"
        case .togglePlayPause: return "togglePlayPause"
        case .nextTrack: return "nextTrack"
        case .previousTrack: return "previousTrack"
        case .seek: return "seek"
        }
    }
}

/// Tracks third-party media sources registered over AtollRPC, their latest
/// Now Playing state, and routes playback commands back to the owning
/// connection via `ExtensionRPCServer`. Mirrors `ExtensionLiveActivityManager`
/// in shape, but doesn't need its cross-process broadcast: only
/// `MusicManager`, in the same process, ever reads this.
///
/// Intentionally not `@MainActor`: `MediaControllerType.localizedName` reads
/// `selectedSource` synchronously from arbitrary (nonisolated) contexts,
/// matching how the rest of this extension-authorization stack isn't
/// actor-isolated either.
final class ExtensionMediaSourceManager: ObservableObject {
    static let shared = ExtensionMediaSourceManager()

    @Published private(set) var sources: [String: ExtensionMediaSourceDescriptor] = [:]
    @Published private(set) var nowPlayingStates: [String: ExtensionMediaSourceNowPlaying] = [:]

    private init() {}

    // MARK: - Registration

    func register(_ descriptor: ExtensionMediaSourceDescriptor) {
        sources[descriptor.sourceID] = descriptor
    }

    func unregister(sourceID: String, bundleIdentifier: String) {
        guard sources[sourceID]?.bundleIdentifier == bundleIdentifier else { return }
        sources.removeValue(forKey: sourceID)
        nowPlayingStates.removeValue(forKey: sourceID)
    }

    /// Drops every source owned by a connection that just disconnected, so
    /// nothing goes stale in the picker or the Now Playing card.
    func unregisterAll(forBundleIdentifier bundleIdentifier: String) {
        for sourceID in sources.filter({ $0.value.bundleIdentifier == bundleIdentifier }).keys {
            sources.removeValue(forKey: sourceID)
            nowPlayingStates.removeValue(forKey: sourceID)
        }
    }

    func owner(of sourceID: String) -> String? {
        sources[sourceID]?.bundleIdentifier
    }

    func updateNowPlaying(_ state: ExtensionMediaSourceNowPlaying) {
        guard sources[state.sourceID] != nil else { return }
        nowPlayingStates[state.sourceID] = state
    }

    // MARK: - Selection

    /// The source backing `MediaControllerType.thirdParty`: whichever the
    /// user selected, or the first registered source if nothing (or a
    /// since-disconnected source) is selected.
    var selectedSource: ExtensionMediaSourceDescriptor? {
        if let selectedID = Defaults[.selectedThirdPartyMediaSourceID], let match = sources[selectedID] {
            return match
        }
        return sources.values.sorted { $0.sourceID < $1.sourceID }.first
    }

    var selectedNowPlaying: ExtensionMediaSourceNowPlaying? {
        guard let sourceID = selectedSource?.sourceID else { return nil }
        return nowPlayingStates[sourceID]
    }

    // MARK: - Commands

    func sendCommand(_ command: ExtensionMediaCommand, to sourceID: String) {
        guard let bundleIdentifier = sources[sourceID]?.bundleIdentifier else { return }
        Task { @MainActor in
            ExtensionRPCServer.shared.notifyMediaCommand(bundleIdentifier: bundleIdentifier, sourceID: sourceID, command: command)
        }
    }
}
