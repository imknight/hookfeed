public struct MessageQuery: Sendable, Equatable {
    public var project: String?
    public var source: String?
    public var bot: String?
    public var unreadOnly: Bool
    public var search: String?
    public var workdirPrefix: String?
    public var limit: Int

    public init(project: String? = nil, source: String? = nil, bot: String? = nil,
                unreadOnly: Bool = false, search: String? = nil, workdirPrefix: String? = nil,
                limit: Int = 20) {
        self.project = project
        self.source = source
        self.bot = bot
        self.unreadOnly = unreadOnly
        self.search = search
        self.workdirPrefix = workdirPrefix
        self.limit = limit
    }
}
