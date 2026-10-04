import SwiftUI

enum ShellStrings {
    static let openSidebar = LocalizedStringResource("sidebar.open", table: "Shell")
    static let closeSidebar = LocalizedStringResource("sidebar.close", table: "Shell")
    static let searchChats = LocalizedStringResource("sidebar.search", table: "Shell")
    static let clearSearch = LocalizedStringResource("sidebar.clearSearch", table: "Shell")
    static let products = LocalizedStringResource("sidebar.products", table: "Shell")
    static let recent = LocalizedStringResource("sidebar.recent", table: "Shell")
    static let noChats = LocalizedStringResource("sidebar.noChats", table: "Shell")
    static let newChat = LocalizedStringResource("sidebar.newChat", table: "Shell")
    static let settings = LocalizedStringResource("sidebar.settings", table: "Shell")
    static let guest = LocalizedStringResource("sidebar.guest", table: "Shell")
    static let account = LocalizedStringResource("sidebar.account", table: "Shell")
    static let deleteChat = LocalizedStringResource("sidebar.deleteChat", table: "Shell")
    static let deleteChatHint = LocalizedStringResource("sidebar.deleteChatHint", table: "Shell")
    static let cancelDeletion = LocalizedStringResource("sidebar.cancelDeletion", table: "Shell")
    static let dismissOverlay = LocalizedStringResource("sidebar.dismissOverlay", table: "Shell")

    static func productTitle(_ product: ProductKind) -> LocalizedStringResource {
        switch product {
        case .ai: LocalizedStringResource("product.ai.title", table: "Shell")
        case .code: LocalizedStringResource("product.code.title", table: "Shell")
        case .brain: LocalizedStringResource("product.brain.title", table: "Shell")
        }
    }

    static func productSubtitle(_ product: ProductKind) -> LocalizedStringResource {
        switch product {
        case .ai: LocalizedStringResource("product.ai.subtitle", table: "Shell")
        case .code: LocalizedStringResource("product.code.subtitle", table: "Shell")
        case .brain: LocalizedStringResource("product.brain.subtitle", table: "Shell")
        }
    }

    static func productSystemImage(_ product: ProductKind) -> String {
        switch product {
        case .ai: "bubble.left.and.bubble.right"
        case .code: "terminal"
        case .brain: "brain.head.profile"
        }
    }
}
