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
import Combine

/// Bridges the media source registered by a third-party extension (over
/// AtollRPC's `atoll.registerMediaSource`/`publishNowPlayingState`) into
/// `MusicManager`, matching every other `MediaControllerProtocol`
/// conformance. Backed by `ExtensionMediaSourceManager` rather than talking
/// to the source directly: the manager already tracks the live RPC
/// connection and owns command/state delivery.
class ThirdPartyMediaSourceController: MediaControllerProtocol {
    @Published private var playbackState: PlaybackState

    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    var isWorking: Bool { manager.selectedSource != nil }

    private let manager: ExtensionMediaSourceManager
    private var cancellable: AnyCancellable?

    /// Fails when no third-party media source is currently registered, same
    /// as every other controller returning `nil` when its app isn't running.
    init?(manager: ExtensionMediaSourceManager = .shared) {
        guard manager.selectedSource != nil else { return nil }
        self.manager = manager
        self.playbackState = Self.makePlaybackState(manager: manager)

        cancellable = Publishers.CombineLatest(manager.$sources, manager.$nowPlayingStates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                guard let self else { return }
                self.playbackState = Self.makePlaybackState(manager: self.manager)
            }
    }

    private static func makePlaybackState(manager: ExtensionMediaSourceManager) -> PlaybackState {
        guard let source = manager.selectedSource else {
            return PlaybackState(bundleIdentifier: "")
        }
        guard let now = manager.selectedNowPlaying, now.sourceID == source.sourceID else {
            return PlaybackState(bundleIdentifier: source.bundleIdentifier, title: source.name, artist: "", album: "")
        }

        // Interpolate elapsed time forward from the snapshot's timestamp
        // while playing, matching how the RPC payload describes it.
        let elapsed = now.isPlaying
            ? now.elapsedTime + Date().timeIntervalSince(now.timestamp)
            : now.elapsedTime

        return PlaybackState(
            bundleIdentifier: source.bundleIdentifier,
            isPlaying: now.isPlaying,
            title: now.title,
            artist: now.artist,
            album: now.album,
            currentTime: max(0, elapsed),
            duration: now.duration ?? 0,
            lastUpdated: now.timestamp,
            artwork: now.artworkData
        )
    }

    private var selectedSourceID: String? { manager.selectedSource?.sourceID }

    func play() async {
        guard let sourceID = selectedSourceID else { return }
        manager.sendCommand(.play, to: sourceID)
    }

    func pause() async {
        guard let sourceID = selectedSourceID else { return }
        manager.sendCommand(.pause, to: sourceID)
    }

    func togglePlay() async {
        guard let sourceID = selectedSourceID else { return }
        manager.sendCommand(.togglePlayPause, to: sourceID)
    }

    func seek(to time: Double) async {
        guard let sourceID = selectedSourceID, manager.selectedSource?.supportsSeek == true else { return }
        manager.sendCommand(.seek(to: time), to: sourceID)
    }

    func nextTrack() async {
        guard let sourceID = selectedSourceID, manager.selectedSource?.supportsSkip == true else { return }
        manager.sendCommand(.nextTrack, to: sourceID)
    }

    func previousTrack() async {
        guard let sourceID = selectedSourceID, manager.selectedSource?.supportsSkip == true else { return }
        manager.sendCommand(.previousTrack, to: sourceID)
    }

    /// Not part of `ExtensionMediaCommand`; third-party sources don't expose
    /// shuffle/repeat toggling yet.
    func toggleShuffle() async {}
    func toggleRepeat() async {}

    func isActive() -> Bool {
        manager.selectedSource != nil
    }

    func updatePlaybackInfo() async {
        playbackState = Self.makePlaybackState(manager: manager)
    }
}
