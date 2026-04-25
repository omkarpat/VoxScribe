# OneDrive Sync Spec

This spec covers a per-user Microsoft OneDrive integration for VoxScribe.

Goal:
- User connects their personal Microsoft account from the iOS Settings screen.
- When the user ends a recording session, VoxScribe uploads the finalized transcript to that user's visible OneDrive root folder.

This is a delegated-auth integration implemented as a **native public client**
on iOS. Files go to the signed-in user's OneDrive, not to the app owner's
OneDrive and not to an app-specific hidden folder.

The backend is not involved in the OneDrive integration. Microsoft OAuth,
refresh-token storage, and Graph uploads all happen on-device.

Relevant current code:
- iOS session lifecycle lives in [`ios/VoxScribe/VoxScribe/Session/TranscriptionSession.swift`](ios/VoxScribe/VoxScribe/Session/TranscriptionSession.swift)
- iOS main recording UI lives in [`ios/VoxScribe/VoxScribe/Views/TranscriptionView.swift`](ios/VoxScribe/VoxScribe/Views/TranscriptionView.swift)
- iOS settings UI lives in [`ios/VoxScribe/VoxScribe/Views/SettingsView.swift`](ios/VoxScribe/VoxScribe/Views/SettingsView.swift)

## Architecture at a glance

- iOS runs a standard authorization-code + PKCE OAuth flow against Microsoft directly, using `ASWebAuthenticationSession`.
- Microsoft redirects to a custom URL scheme registered by the iOS app.
- iOS stores the resulting refresh token in Keychain.
- Before each upload, iOS refreshes the access token as needed and uploads the transcript directly to Microsoft Graph.
- The Railway backend is unchanged by this feature.

## Current External Setup Context

This spec assumes the Microsoft setup described below is in place.

### Microsoft Entra

Current production assumptions:
- App registration name: `VoxScribe`
- Application (client) ID: `2c5a12d1-411d-4b5f-a1d4-1bff67c29e73`
- Supported account types: `Personal Microsoft accounts only`
- Platform type: `Mobile and desktop applications` (public client)
- Bundle ID: `com.omkarpatil.VoxScribe`
- Redirect URI:
  - `msauth.com.omkarpatil.VoxScribe://auth`
- Authority:
  - `https://login.microsoftonline.com/consumers`
- Microsoft Graph delegated permission:
  - `Files.ReadWrite`
  - `User.Read`
- OAuth/OpenID scopes requested by the app:
  - `openid`
  - `profile`
  - `offline_access`
  - `Files.ReadWrite`
  - `User.Read`

The redirect URI follows the bundle-namespaced `msauth.<bundleid>://auth`
convention. We do not depend on the MSAL SDK; the scheme is just registered
in `CFBundleURLTypes` and handled directly via `ASWebAuthenticationSession`.

Required authentication settings for this integration:
- Public client. No client secret.
- PKCE is enforced by the app on every authorize request.
- `Allow public client flows` (legacy auth) is not enabled and is not required.
- Implicit grant / hybrid flow checkboxes are not enabled.
- Front-channel logout URL is not required for v1.

Operational note:
- The Microsoft app registration tenant only defines the app.
- Upload destination is still determined by the signed-in user's delegated token.
- With this delegated setup, files go to the signed-in user's OneDrive, not to the Entra tenant owner's OneDrive.

## Goals

- Let a user connect their Microsoft account from Settings.
- Keep the current recording flow simple: stopping the session is the upload trigger.
- Upload the final transcript to the user's OneDrive root so they can see it in normal OneDrive views.
- Keep failure behavior safe: transcript creation must never depend on OneDrive upload success.
- Keep the current "no VoxScribe user accounts" product direction intact.
- Keep the server free of per-user state.

## Non-goals

- Multi-device account sync across a VoxScribe identity.
- Shared/team OneDrive destinations.
- Folder picker UI.
- Uploading audio files.
- App-folder-based storage (`Apps/VoxScribe`) for v1.
- Server-side token storage or server-side Microsoft OAuth.
- Background token refresh while the app is not running (iOS `BGTaskScheduler`).
- Keeping dormant connections alive beyond Microsoft's default refresh-token window.

## Product Summary

V1 behavior:
- Settings shows a `OneDrive` section.
- User taps `Connect Microsoft`.
- iOS opens the Microsoft authorize endpoint in `ASWebAuthenticationSession`.
- User signs in with Microsoft and consents to OneDrive access.
- Microsoft redirects back to `msauth.com.omkarpatil.VoxScribe://auth` with an auth code.
- iOS exchanges the code (PKCE) for access + refresh tokens and stores them in Keychain.
- When the user stops recording, iOS finalizes the transcript, refreshes the access token if needed, and uploads a plain text transcript file to the user's OneDrive root.

If the user never connects Microsoft:
- The app behaves exactly as it does today.

If the user is connected but upload fails:
- The recording still ends normally.
- The transcript remains available locally.
- The app surfaces a non-blocking error state and keeps a pending upload record for retry.

Once a user connects Microsoft:
- Access-token refresh and refresh-token rotation happen automatically on-device.
- Users should not need to reconnect just because an access token expired.
- iOS replaces stored refresh tokens whenever Microsoft rotates them.

If a user stays dormant long enough that their refresh token expires
(Microsoft's default window), they reconnect from Settings. This is the
accepted v1 tradeoff for not running a server-side keepalive job.

## Why This Shape

The app currently has:
- no VoxScribe auth system
- no user database
- transcript state that lives in memory during the session

That means the integration must:
- avoid introducing full app accounts
- avoid introducing server-side per-user state
- snapshot the final transcript locally before attempting upload

Running the OAuth client entirely on-device satisfies all three: Microsoft
already provides durable identity for the user, Keychain already provides
durable secret storage on the device, and the server stays stateless.

## User Experience

### Settings

Add a new `OneDrive` section to Settings.

Disconnected state:
- Row: `Connect Microsoft`
- Footer: `Completed sessions can upload automatically to your OneDrive.`

Connected state:
- Row: `Connected`
- Secondary text: connected Microsoft email
- Row: `Disconnect`
- Footer: `Completed sessions upload automatically to your OneDrive root folder.`

Uploading state:
- Optional secondary text: `Last upload in progress...`

Error state:
- Secondary text: `Last upload failed`
- Footer: brief retry guidance

Reconnect-required state (refresh token invalid):
- Secondary text: `Microsoft connection expired`
- Footer: `Tap Connect Microsoft to reauthorize.`

Constraints:
- Disable connect/disconnect while recording.
- Keep the UX minimal. No folder picker in v1.

### Recording Flow

Current user action:
- Tap record to start.
- Tap stop to end.

New behavior on stop:
1. Stop capture.
2. Finalize transcript.
3. If Microsoft is connected, enqueue/upload the transcript.
4. Show success silently or a small non-blocking error if upload fails.

No extra "End Transcript" button is required for v1. The existing stop action is
the end-of-session action.

## OneDrive Destination

Upload destination is the user's visible OneDrive root.

Graph upload shape:

```text
PUT /me/drive/root:/<filename>:/content
```

Example:

```text
PUT /me/drive/root:/VoxScribe Transcript 2026-04-24 15-05-12.txt:/content
```

This creates a normal top-level file in the user's OneDrive that they can see in:
- OneDrive web
- OneDrive iOS app
- OneDrive desktop sync

## Auth Model

This integration uses delegated Microsoft OAuth, implemented as a native public
client with PKCE. The iOS app is the OAuth client; there is no confidential
server component.

Important rule:
- every user signs into their own Microsoft account
- every upload uses that user's delegated refresh/access token

This is what makes the file land in that user's OneDrive.

Not allowed for this feature:
- one global Microsoft refresh token on the server
- application-only Graph permissions
- a shared server-owned OneDrive account
- embedding a client secret in the iOS app
- using a confidential-client OAuth flow

### OAuth flow

1. iOS generates a random `code_verifier` and derives the SHA256-based `code_challenge` (RFC 7636).
2. iOS generates a random `state`.
3. iOS opens `ASWebAuthenticationSession` pointing at:

   ```text
   https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize
       ?client_id={MICROSOFT_CLIENT_ID}
       &response_type=code
       &redirect_uri=msauth.com.omkarpatil.VoxScribe://auth
       &response_mode=query
       &scope=openid%20profile%20offline_access%20Files.ReadWrite%20User.Read
       &state={state}
       &code_challenge={code_challenge}
       &code_challenge_method=S256
   ```

4. User signs in with Microsoft and consents.
5. Microsoft redirects to `msauth.com.omkarpatil.VoxScribe://auth?code=...&state=...`.
6. iOS validates `state`, then POSTs to:

   ```text
   https://login.microsoftonline.com/consumers/oauth2/v2.0/token
   ```

   with `grant_type=authorization_code`, `code`, `redirect_uri`, `client_id`, and `code_verifier`.
7. Microsoft returns `access_token`, `refresh_token`, `expires_in`, `scope`.
8. iOS calls Graph `/me` once with the access token to capture `email` and `displayName` for Settings.
9. iOS stores `refresh_token`, `access_token`, `access_token_expires_at`, `scope`, `email`, `display_name` in Keychain.

### Token refresh

Before any Graph call, iOS checks `access_token_expires_at`. If the token is
expired or within a 2-minute safety margin, iOS POSTs to the token endpoint:

```text
grant_type=refresh_token
refresh_token={current_refresh_token}
client_id={MICROSOFT_CLIENT_ID}
scope=openid profile offline_access Files.ReadWrite User.Read
```

On success:
- Replace `access_token` and `access_token_expires_at`.
- If the response includes a new `refresh_token`, atomically replace the stored refresh token with it. Do not keep the old one.

On terminal failure (`invalid_grant`, `interaction_required`, etc.):
- Clear stored tokens.
- Set connection state to `expired`.
- Keep the transcript pending; surface the reconnect-required UI state.

### Security rules

- No client secret. Ever.
- PKCE is required on every authorize request.
- `state` is checked on every callback; mismatches are rejected.
- Refresh tokens live only in iOS Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so they never sync to iCloud Keychain and are never readable before first unlock.
- Never log access tokens, refresh tokens, auth codes, or transcript bodies.

## iOS Changes

### 1. Microsoft OAuth configuration

Add a small config value for the Microsoft client ID. This is public, so it can
live in build config or a plist; it is not a secret.

Suggested constants:
- `MicrosoftOAuthConfig.clientId`
- `MicrosoftOAuthConfig.authority = "https://login.microsoftonline.com/consumers"`
- `MicrosoftOAuthConfig.redirectURI = "msauth.com.omkarpatil.VoxScribe://auth"`
- `MicrosoftOAuthConfig.scopes = ["openid", "profile", "offline_access", "Files.ReadWrite", "User.Read"]`

### 2. Custom URL scheme

App configuration required:
- add `msauth.com.omkarpatil.VoxScribe` to `CFBundleURLTypes` in `Info.plist`

`ASWebAuthenticationSession` intercepts the callback via its
`callbackURLScheme` parameter, so no `onOpenURL` handler is needed on
`VoxScribeApp`.

### 3. Keychain token store

Add a Keychain-backed token store.

Responsibilities:
- Persist `access_token`, `refresh_token`, `access_token_expires_at`, `scope`, `email`, `display_name`.
- Provide atomic read/write so refresh-token rotation cannot leave the device with two simultaneously valid tokens on disk.
- Default accessibility: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.

Suggested type:
- `MicrosoftTokenStore`

### 4. OAuth coordinator

Add a coordinator that runs the OAuth flow via `ASWebAuthenticationSession`.

Responsibilities:
- Generate `code_verifier`, `code_challenge`, `state`.
- Build authorize URL, present web auth session.
- Parse callback URL.
- Exchange code for tokens.
- Fetch `/me` metadata.
- Persist tokens to `MicrosoftTokenStore`.

Suggested type:
- `MicrosoftAuthCoordinator`

### 5. Token refresh service

A small service every Graph call goes through.

Responsibilities:
- Read stored tokens.
- If access token is expired or near expiry, call token endpoint with refresh token.
- Rotate the stored refresh token if Microsoft returns a new one.
- On terminal failure, mark connection expired and clear tokens.

Suggested type:
- `MicrosoftTokenRefresher`

### 6. OneDrive connection state

Add a local store for integration state.

Suggested model:

```swift
struct OneDriveConnectionState: Codable, Equatable {
    enum Status: String, Codable { case disconnected, connected, expired }
    var status: Status
    var email: String?
    var displayName: String?
    var lastUploadAt: Date?
    var lastUploadStatus: UploadStatus?
}
```

Suggested type:
- `OneDriveConnectionStore`

Persistence:
- `UserDefaults` is acceptable for this UI state.
- Keychain remains the source of truth for tokens.

### 7. Settings UI

Extend [`SettingsView.swift`](ios/VoxScribe/VoxScribe/Views/SettingsView.swift):
- Add a `OneDrive` section.
- Wire it to:
  - start connect flow
  - disconnect (clear Keychain + connection state)
  - reflect current state (disconnected / connected / uploading / error / expired)

### 8. Transcript finalization

Current issue:
- [`TranscriptionSession.swift`](ios/VoxScribe/VoxScribe/Session/TranscriptionSession.swift) launches correction requests in detached tasks when turns finalize.
- `stop()` does not currently wait for those correction tasks to finish.

This creates a race:
- user taps stop
- upload begins
- last corrected segments may not be applied yet

Spec requirement:
- add a session finalization step that waits for in-flight corrections before producing the upload snapshot

Suggested API:

```swift
func finalizeForExport() async -> FinalizedTranscript
```

Suggested `FinalizedTranscript`:

```swift
struct FinalizedTranscript: Sendable, Equatable {
    let sessionId: String?
    let startedAt: Date
    let endedAt: Date
    let mode: CorrectionMode
    let transcriber: Transcriber
    let segments: [TranscriptSegment]
    let renderedText: String
}
```

Rules:
- Only corrected/raw final segments are included.
- `partial` text is never included.
- Rendered text should match what the user sees.

### 9. Local pending upload persistence

Before sending to Graph, persist a local upload job in Application Support.

Reason:
- If the app is terminated or network upload fails, the transcript must not be lost.

Suggested model:

```swift
struct PendingTranscriptUpload: Codable, Identifiable {
    let id: String
    let createdAt: Date
    let transcript: FinalizedTranscriptPayload
    var attempts: Int
}
```

Suggested type:
- `TranscriptUploadStore`

Behavior:
- Save pending upload before network call.
- Delete pending upload only after Graph confirms upload success.
- Retry pending uploads on next app launch and after future successful session stops.

### 10. Graph upload client

Use Microsoft Graph small file upload.

Request:

```text
PUT https://graph.microsoft.com/v1.0/me/drive/root:/<filename>:/content
Authorization: Bearer <access_token>
Content-Type: text/plain
```

This is sufficient for transcript-sized text files. No large-file upload
session is needed for v1.

Retry behavior:
- On 401, force a token refresh and retry once.
- On 5xx / network error, keep pending upload and retry later.
- On terminal 4xx other than 401, keep pending upload and surface error.

Suggested type:
- `OneDriveUploader`

## Server Changes

None for v1.

The backend is untouched by this feature. `/correct` and `/correct_code` remain
the only user-facing server concerns.

## File Naming

Keep filenames deterministic and readable.

Recommended format:

```text
VoxScribe Transcript YYYY-MM-DD HH-MM-SS.txt
```

Use the session end timestamp for the filename.

Examples:
- `VoxScribe Transcript 2026-04-24 15-14-48.txt`
- `VoxScribe Transcript 2026-04-24 16-03-09.txt`

## File Contents

Plain text is enough for v1.

Suggested body:

```text
VoxScribe Transcript
Started: 2026-04-24T22:01:12Z
Ended: 2026-04-24T22:14:48Z
Mode: standard
Transcriber: standard

Final transcript text goes here.
```

This keeps the file human-readable and easy to search.

## End-Session Upload Flow

Exact flow for a connected user:

1. User taps stop in the recording UI.
2. iOS stops capture.
3. iOS calls `finalizeForExport()`.
4. Final transcript snapshot is rendered.
5. iOS writes a pending upload record to Application Support.
6. iOS refreshes the access token if needed (rotating the refresh token if Microsoft returns a new one).
7. iOS `PUT`s the file to `/me/drive/root:/<filename>:/content`.
8. iOS marks upload successful and deletes the pending local upload record.

For a disconnected user:
1. Steps 1-4 still happen.
2. Upload is skipped.
3. No error is shown.

## Error Handling

### Microsoft Not Connected

Behavior:
- skip upload
- do not block session completion

### Refresh Token Invalid

Trigger:
- token refresh returns `invalid_grant` or similar terminal auth error

Behavior:
- clear Keychain tokens
- set connection state to `expired`
- keep pending upload record
- show reconnect-required UI state in Settings

### Network Failure

iOS behavior:
- keep pending upload record
- show non-blocking error
- retry later (next app launch or next successful session stop)

### Graph Upload Failure

Rules:
- do not lose transcript
- do not clear local pending upload
- do not show a fatal recording error

## Security Rules

- Use delegated Graph permissions only.
- Request only:
  - `openid`
  - `profile`
  - `offline_access`
  - `Files.ReadWrite`
  - `User.Read`
- No client secret. PKCE only.
- Tokens live only in Keychain with `AfterFirstUnlockThisDeviceOnly` accessibility.
- Replace stored refresh tokens with newly returned refresh tokens whenever they rotate.
- Do not log transcript text, access tokens, refresh tokens, or auth codes.

## Suggested New iOS Types

- `MicrosoftOAuthConfig`
- `MicrosoftTokenStore`
- `MicrosoftAuthCoordinator`
- `MicrosoftTokenRefresher`
- `OneDriveUploader`
- `OneDriveConnectionStore`
- `TranscriptUploadStore`
- `FinalizedTranscript`

## Implementation Order

Recommended order:

1. Add custom URL scheme (`msauth.com.omkarpatil.VoxScribe`) to `Info.plist`.
2. Add `MicrosoftOAuthConfig` + `MicrosoftTokenStore` (Keychain).
3. Add `MicrosoftAuthCoordinator` (authorize + code exchange).
4. Add `MicrosoftTokenRefresher` (refresh + rotation).
5. Add `OneDriveConnectionStore` + Settings UI (connect/disconnect/status).
6. Add transcript finalization step that waits for in-flight corrections.
7. Add local pending-upload persistence.
8. Add `OneDriveUploader` (Graph small-file upload).
9. Hook stop-session flow to upload finalized transcripts.
10. Add retry behavior and polish UI states.

## Acceptance Criteria

- User can connect a personal Microsoft account from Settings.
- After connecting, Settings shows the connected email.
- Stopping a session with OneDrive connected uploads one `.txt` file to the user's visible OneDrive root.
- The file is visible in OneDrive web for the signed-in Microsoft user.
- Upload uses corrected final transcript text, not partials.
- If upload fails, session completion still succeeds and transcript is retained locally for retry.
- Disconnect clears tokens from Keychain and the integration returns to disconnected state.
- Access token expiry does not force a reconnect.
- Refresh-token rotation is automatic whenever Microsoft returns a replacement token.
- If Microsoft revokes access or the refresh flow fails permanently, Settings shows a reconnect-required state.

## Out of Scope For V1

- Choosing a custom OneDrive folder
- Sync status history screen
- Batch upload of historical transcripts
- Markdown or rich-text export
- Cross-device installation/account merge
- Server-side token storage, keepalive, or multi-device sync
- iOS background refresh via `BGTaskScheduler`

## References

Primary docs used for this design:
- [Microsoft identity platform and OAuth 2.0 authorization code flow](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow)
- [Authentication flows and application scenarios — public client desktop/mobile](https://learn.microsoft.com/en-us/entra/identity-platform/authentication-flows-app-scenarios)
- [Microsoft Graph permissions reference](https://learn.microsoft.com/en-us/graph/permissions-reference)
- [Upload small files with Microsoft Graph](https://learn.microsoft.com/en-us/graph/api/driveitem-put-content?view=graph-rest-1.0)
- [Scopes and offline_access](https://learn.microsoft.com/en-us/entra/identity-platform/scopes-oidc)
- [Refresh tokens in the Microsoft identity platform](https://learn.microsoft.com/en-us/entra/identity-platform/refresh-tokens)
