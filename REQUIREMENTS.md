# OpenClaw iOS App — Requirements v1

## Overview
A personal AI life hub iOS app that serves as the single entry point for all AI-assisted daily operations. Connects directly to an OpenClaw Gateway backend via WebSocket.

## Target Users
- **Macheng** (primary user / owner)
- **innocent** (partner)
- **Third user** (to be added later)

## Architecture

### Backend
- **No custom backend** — connects directly to OpenClaw Gateway WebSocket API
- Gateway URL: configurable (default `wss://<host>:18789`)
- Auth: Gateway token-based authentication
- Each channel = one OpenClaw session

### Frontend
- **SwiftUI** (iOS 17+)
- **Native** look and feel, minimal dependencies
- Dark mode support

## Core Features (v1)

### 1. Multi-Channel Chat
The primary interface. Each channel is an independent conversation with OpenClaw.

**Channels:**
- 🔒 Private: User ↔ OpenClaw (1-on-1, each user has their own)
- 👥 Group: All users + OpenClaw (shared group chat)

**Chat features:**
- Text messages (Markdown rendering)
- Image send/receive
- File attachments
- Voice messages (optional v1.1)
- Message history (persisted locally + server-side)
- Pull-to-refresh for older messages
- Reply/quote messages

### 2. Smart Notifications
The killer feature — reliable, alarm-grade reminders.

**Notification tiers:**
- 🔕 Silent: badge only
- 🔔 Normal: banner + sound
- 🚨 Urgent: Time Sensitive (bypasses Focus/DND), repeated alerts

**How it works:**
- OpenClaw sends notification with priority level
- App uses APNs with `interruption-level: time-sensitive` for urgent
- Local notification fallback for calendar reminders
- Custom alarm sounds for urgent notifications

### 3. Calendar Integration
- Display upcoming events from Google Calendar
- Natural language event creation via chat ("明天3点有会" → creates event)
- Local push notifications as backup reminders
- Event detail view with location, notes, attendees

### 4. AI News Feed (v1.1)
- Daily curated AI frontier updates
- Swipe to rate (👍/👎) for taste optimization
- Tap to expand summary → full article
- Push notification for daily digest

### 5. Quick Actions
- 📅 "New event" → opens chat with calendar prompt
- 📧 "Check email" → triggers email summary
- 🔍 "Search" → web search via OpenClaw
- 🤖 "Agent status" → shows running Codex/Claude tasks

### 6. Settings
- Gateway URL configuration
- User profile (name, avatar)
- Notification preferences per channel
- Theme (light/dark/auto)
- Language (Chinese/English, auto-detect)

## Technical Details

### Networking
```
App ←WebSocket→ OpenClaw Gateway (port 18789)
App ←APNs→ Apple Push Notification Service
```

### Data Flow
1. User sends message in chat
2. App sends via WebSocket to Gateway
3. Gateway routes to OpenClaw agent session
4. Agent processes, responds via WebSocket
5. App displays response in chat bubble
6. If notification needed: Gateway → APNs → iOS notification

### Local Storage
- Chat history: Core Data or SwiftData
- User preferences: UserDefaults
- Media cache: FileManager

### Push Notifications
- Requires APNs certificate/key in Apple Developer account
- Server-side: OpenClaw Gateway sends push via APNs
- Support for: alert, badge, sound, interruption-level

## UI Design

### Main Navigation (Tab Bar)
1. 💬 **Chat** — channel list → chat view
2. 📅 **Calendar** — upcoming events
3. 🔔 **Notifications** — activity feed
4. ⚙️ **Settings**

### Chat List View
- Channel avatar + name
- Last message preview + timestamp
- Unread badge count
- Swipe actions (pin, mute, archive)

### Chat Detail View
- Message bubbles (left: OpenClaw, right: user)
- Markdown rendering (code blocks, bold, links, lists)
- Image inline display
- Input bar: text field + send button + attachment (+) button
- Typing indicator

### Color Scheme
- Primary: Deep blue (#1a1a2e)
- Accent: Electric blue (#4361ee)
- Background: #0f0f1a (dark) / #ffffff (light)
- Clean, modern, minimal — inspired by Telegram/Signal

## V1 Scope (MVP)
- [x] Multi-channel chat with OpenClaw
- [x] WebSocket connection to Gateway
- [x] Local push notifications (alarm-grade)
- [x] Basic settings (URL, profile)
- [x] Markdown message rendering
- [x] Image send/receive
- [x] Dark mode

## V1.1 (Fast Follow)
- [ ] APNs remote push notifications
- [ ] Calendar view integration
- [ ] AI News feed
- [ ] Voice messages
- [ ] Agent task panel
- [ ] Quick actions widget

## V2 (Future)
- [ ] End-to-end encryption
- [ ] Voice/video call to OpenClaw
- [ ] Widgets (iOS home screen)
- [ ] Apple Watch companion
- [ ] Shortcuts integration

## Notes
- App name TBD (suggestions: "Claw", "OpenClaw", or something custom)
- No App Store review needed initially — use TestFlight for distribution
- All three users should be able to install via TestFlight link
- Bilingual UI: follow system language, Chinese/English
