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
import Defaults
import SwiftUI

struct GoogleCalendarSettingsSection: View {
    @Default(.googleCalendarClientID) private var clientID
    @ObservedObject private var manager = GoogleCalendarManager.shared
    @State private var clientSecretField: String = ""
    @State private var showingClientSecret = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Connects directly to your Google account via OAuth, independent of macOS's own Calendar app. Create a free OAuth client at console.cloud.google.com (APIs & Services → Credentials → Create Credentials → OAuth client ID → **Desktop app**), enable the Calendar API for that project, then paste its Client ID and Client Secret here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Client ID", text: $clientID)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())

                HStack(spacing: 6) {
                    if showingClientSecret {
                        TextField("Client Secret", text: $clientSecretField)
                    } else {
                        SecureField("Client Secret", text: $clientSecretField)
                    }
                    Button {
                        showingClientSecret.toggle()
                    } label: {
                        Image(systemName: showingClientSecret ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                }
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .onChange(of: clientSecretField) { _, newValue in
                    manager.clientSecret = newValue
                }
            }

            HStack(spacing: 10) {
                Circle()
                    .fill(manager.isAuthenticated ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)

                Text(statusText)
                    .foregroundStyle(.secondary)
            }

            if let error = manager.error {
                Text(message(for: error))
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button(manager.isAuthorizing ? "Connecting…" : "Connect Google Calendar") {
                    manager.connect()
                }
                .disabled(
                    clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || clientSecretField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || manager.isAuthorizing
                )

                Button("Disconnect") {
                    manager.disconnect()
                }
                .disabled(!manager.isAuthenticated)

                Link("Open Google Cloud Console", destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                    .font(.caption)
            }
        } header: {
            Text("Google Calendar")
        } footer: {
            Text("Read-only access to your Google Calendar events, merged into Atoll's calendar alongside any macOS calendars. While your OAuth consent screen is in \"Testing\" publish status, Google expires the connection after 7 days — reconnect here when that happens, or publish the app in Google Cloud Console to remove the limit.")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .onAppear {
            clientSecretField = manager.clientSecret
        }
    }

    /// Derived from the view's own bindings rather than the manager's copy,
    /// so the line updates while the user is still typing.
    private var statusText: String {
        if manager.isAuthenticated {
            return String(localized: "Connected — Google Calendar events are showing.")
        }
        if clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || clientSecretField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "Not connected.")
        }
        return String(localized: "Credentials saved. Connect your Google account.")
    }

    private func message(for error: GoogleCalendarError) -> String {
        switch error {
        case .missingClientID:
            return String(localized: "Paste the Client ID of your Google Cloud OAuth client first.")
        case .missingClientSecret:
            return String(localized: "Paste the Client Secret of your Google Cloud OAuth client first.")
        case .secureRandomUnavailable:
            return String(localized: "Unable to generate secure random data for the login.")
        case .canceled:
            return ""
        case .loopbackServerFailed(let description):
            return String(localized: "Could not start the local sign-in listener: \(description)")
        case .missingAuthorizationCode:
            return String(localized: "Google did not return an authorization code.")
        case .stateMismatch:
            return String(localized: "Google sign-in response didn't match the request. Try connecting again.")
        case .tokenExchangeFailed(let description):
            return String(localized: "Token exchange failed: \(description)")
        case .refreshTokenRevoked:
            return String(localized: "Google revoked access. Connect your account again.")
        }
    }
}
