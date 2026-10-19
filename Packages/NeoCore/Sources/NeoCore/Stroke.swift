/// A stroke that the assembler has completed.
///
/// The points are in event order. Nothing in the canonical encoding depends on
/// `source`, which is why a live stroke and an offline stroke of the same
/// physical mark can produce the same fingerprint.
public struct Stroke: Hashable, Sendable, Codable {
    /// The page the stroke belongs to.
    public let page: PageIdentity

    /// The stroke's pen-origin start time.
    public let originTime: PenOriginTime

    /// Ordered normalized points.
    public let points: [PenPoint]

    /// Where the stroke came from.
    public let source: PenSource

    public init(page: PageIdentity, originTime: PenOriginTime, points: [PenPoint], source: PenSource) {
        self.page = page
        self.originTime = originTime
        self.points = points
        self.source = source
    }
}
