import Foundation
import SwiftData

@Model
final class Message {
    @Attribute(.unique) var id: UUID
    var text: String
    var senderName: String
    var isFromUser: Bool
    var sentAt: Date
    var remoteMessageKey: String?

    @Relationship var channel: Channel?

    init(
        id: UUID = UUID(),
        text: String,
        senderName: String,
        isFromUser: Bool,
        sentAt: Date = .now,
        remoteMessageKey: String? = nil,
        channel: Channel? = nil
    ) {
        self.id = id
        self.text = text
        self.senderName = senderName
        self.isFromUser = isFromUser
        self.sentAt = sentAt
        self.remoteMessageKey = remoteMessageKey
        self.channel = channel
    }
}
