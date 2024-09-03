public struct MSKTiledTile: Equatable, Hashable, Decodable {
    public let column: Int
    public let row: Int

    public init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }

    public static func == (lhs: MSKTiledTile, rhs: MSKTiledTile) -> Bool {
        return lhs.column == rhs.column && lhs.row == rhs.row
    }
}
