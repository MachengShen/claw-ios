import Foundation
import SwiftData

@Model
final class Channel {
    @Attribute(.unique) var id: UUID
    var name: String
    var isPrivate: Bool
    var createdAt: Date
    var unreadCount: Int

    @Relationship(deleteRule: .cascade, inverse: \Message.channel)
    var messages: [Message]

    @Transient
    var lastMessage: Message? {
        messages.max(by: { $0.sentAt < $1.sentAt })
    }

    init(
        id: UUID = UUID(),
        name: String,
        isPrivate: Bool,
        createdAt: Date = .now,
        unreadCount: Int = 0,
        messages: [Message] = []
    ) {
        self.id = id
        self.name = name
        self.isPrivate = isPrivate
        self.createdAt = createdAt
        self.unreadCount = unreadCount
        self.messages = messages
    }
}
