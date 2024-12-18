import SpriteKit
import GameplayKit

private struct LayerToAdd {
    let tileSet: SKTileSet
    let layerData: [Int]
    let rawLayer: RawLayer
}

// swiftlint:disable:next type_body_length
public final class MSKTiledMapParser: NSObject, XMLParserDelegate, @unchecked Sendable {

    private var characters = ""
    private var encodingType: EncodingType = .csv

    private var tileGroups = [SKTileGroup]()
    private var layers = [LayerToAdd]()

    private var tileSize = CGSize()
    private var mapSize = CGSize()

    private var textureCache = [String: SKTexture]()

    private var currentRawTile: RawTile?
    private var rawTiles = [RawTile]()

    private var currentRawTileSet: RawTileSet?
    private var rawTileSets = [RawTileSet]()

    private var currentRawLayer: RawLayer?
    private var addingCustomTileGroups: [SKTileGroup]?

    private var currentTiledObjectGroup: MSKTiledObjectGroup?
    private var tiledObjectGroups = [MSKTiledObjectGroup]()

    private var currentTiledObject: MSKTiledObject?
    private var fileName = ""

    private var didParseFinish = false

    public var isParserReady: Bool {
        return didParseFinish
    }

    @MainActor
    public func getTileMapNodes() -> (layers: [SKTileMapNode],
                                      tileGroups: [SKTileGroup],
                                      tiledObjectGroups: [MSKTiledObjectGroup]?) {
        let tileMapNodeLayers: [SKTileMapNode] = layers.map { layer in
            let tileSet = layer.tileSet
            let rawLayer = layer.rawLayer
            let layerData = layer.layerData
            let tileMapNode = SKTileMapNode(tileSet: tileSet, columns: Int(mapSize.width), rows: Int(mapSize.height), tileSize: tileSize)

            var idx = 0
            for tileId in layerData {
                if !hasValidTileData(tileId: tileId) {
                    idx+=1
                    continue
                }
                var column = 0
                if idx > 0 {
                    column = idx%Int(mapSize.width)
                }
                let row = Int(mapSize.height-1)-Int(floor(CGFloat(idx)/mapSize.width))

                let tileGroup = getTileGroup(tileId: tileId)
                tileMapNode.setTileGroup(tileGroup, forColumn: column, row: row)
                idx+=1
            }
            tileMapNode.name = rawLayer.name
            if rawLayer.invisible {
                tileMapNode.alpha = 0
            }
            return tileMapNode
        }
        return (tileMapNodeLayers, tileGroups, tiledObjectGroups)
    }

    public func loadTilemap(filename: String, addingCustomTileGroups: [SKTileGroup]? = nil) {
        self.fileName = filename
        self.addingCustomTileGroups = addingCustomTileGroups
        guard let path = Bundle.main.url(forResource: filename, withExtension: ".tmx") else {
            log(logLevel: .error, message: "Failed to locate tilemap \(filename) in bundle")
            return
        }
        guard let parser = XMLParser(contentsOf: path) else {
            log(logLevel: .error, message: "Failed to load xml tilemap \(filename)")
            return
        }

        parser.delegate = self
        parser.parse()

        didParseFinish = true
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public func parser(_ parser: XMLParser,
                       didStartElement elementName: String,
                       namespaceURI: String?,
                       qualifiedName qName: String?,
                       attributes attributeDict: [String: String]) {
        if elementName == ElementName.map.rawValue {
            guard let mapWidth = getDoubleValueFromAttributes(attributeDict, attributeName: .width),
                  let mapHeight = getDoubleValueFromAttributes(attributeDict, attributeName: .height) else {
                log(logLevel: .error, message: "Map found without a size definition: LINE[\(parser.lineNumber)]")
                parser.abortParsing()
                return
            }
            guard let tileWidth = getDoubleValueFromAttributes(attributeDict, attributeName: .tilewidth),
                  let tileHeight = getDoubleValueFromAttributes(attributeDict, attributeName: .tileheight) else {
                log(logLevel: .error, message: "Map found without a tilesize definition: LINE[\(parser.lineNumber)]")
                parser.abortParsing()
                return
            }
            mapSize = .init(width: mapWidth, height: mapHeight)
            tileSize = .init(width: tileWidth, height: tileHeight)
        } else if elementName == ElementName.tileset.rawValue {
            guard let tileWidth = getDoubleValueFromAttributes(attributeDict, attributeName: .tilewidth),
                  let tileHeight = getDoubleValueFromAttributes(attributeDict, attributeName: .tileheight) else {
                log(logLevel: .error, message: "Tileset found without tilesize definitions: LINE[\(parser.lineNumber)]")
                parser.abortParsing()
                return
            }
            if tileSize.width != tileWidth || tileSize.height != tileHeight {
                log(logLevel: .error, message: "Tileset found with a different tilesize (\(tileWidth),\(tileHeight) than defined on the map (\(tileSize)): LINE[\(parser.lineNumber)]")
                parser.abortParsing()
                return
            }
            guard let firstGid = getIntValueFromAttributes(attributeDict, attributeName: .firstgid),
                  let tileCount = getIntValueFromAttributes(attributeDict, attributeName: .tilecount),
                  let columns = getIntValueFromAttributes(attributeDict, attributeName: .columns) else {
                log(logLevel: .error, message: "Invalid tileset found. Check existence of firstgid, tilecount and columns: LINE[\(parser.lineNumber)]")
                parser.abortParsing()
                return
            }
            currentRawTileSet = RawTileSet(firstGid: firstGid, tileCount: tileCount, image: "", columns: columns)
        } else if elementName == ElementName.image.rawValue {
            guard let currentRawTileSet = currentRawTileSet else {
                log(logLevel: .error, message: "Images are only supported for tilesets at the moment: LINE[\(parser.lineNumber)]")
                return
            }
            guard let source = getStringValueFromAttributes(attributeDict, attributeName: .source) else {
                log(logLevel: .error, message: "Tileset image found without a valid source: LINE[\(parser.lineNumber)]")
                parser.abortParsing()
                return
            }

            let rawTileSet = RawTileSet(firstGid: currentRawTileSet.firstGid, tileCount: currentRawTileSet.tileCount, image: source, columns: currentRawTileSet.columns)
            rawTileSets.append(rawTileSet)
        } else if elementName == ElementName.tile.rawValue {
            guard let currentRawTileSet = currentRawTileSet else {
                log(logLevel: .error, message: "Tile found not embedded in a tileset: LINE[\(parser.lineNumber)]")
                return
            }

            if let tileId = getIntValueFromAttributes(attributeDict, attributeName: .id) {
                currentRawTile = .init(id: tileId+currentRawTileSet.firstGid, properties: nil)
            } else {
                log(logLevel: .error, message: "Tile found without an id: LINE[\(parser.lineNumber)]")
                parser.abortParsing()
                return
            }
        } else if elementName == ElementName.property.rawValue {
            guard
                let name = getStringValueFromAttributes(attributeDict, attributeName: .name),
                let value = getStringValueFromAttributes(attributeDict, attributeName: .value)
            else {
                log(logLevel: .error, message: "Invalid property found: LINE[\(parser.lineNumber)]")
                return
            }
            var propertyValue: Any = value
            if let type = getStringValueFromAttributes(attributeDict, attributeName: .type) {
                if let propertyType = PropertyType.init(rawValue: type) {
                    if propertyType == .bool {
                        if let boolValue = Bool(value) {
                            propertyValue = boolValue
                        } else {
                            log(logLevel: .error, message: "Invalid property boolean found: LINE[\(parser.lineNumber)]")
                            return
                        }
                    } else if propertyType == .int {
                        if let integerValue = Int(value) {
                            propertyValue = integerValue
                        } else {
                            log(logLevel: .error, message: "Invalid property integer found: LINE[\(parser.lineNumber)]")
                            return
                        }
                    }
                } else {
                    log(logLevel: .error, message: "Unsupported property type found: LINE[\(parser.lineNumber)]")
                    return
                }
            }
            var newProperties = [String: Any]()
            var existingProperties: [String: Any]?
            if currentRawTile != nil {
                existingProperties = currentRawTile?.properties
            } else if currentTiledObject != nil {
                existingProperties = currentTiledObject?.properties
            } else if currentTiledObjectGroup != nil {
                existingProperties = currentTiledObjectGroup?.properties
            } else {
                log(logLevel: .warning, message: "Properties are only supported on tiles, objects and objectgroups")
                return
            }
            if var existingProperties {
                existingProperties[name] = propertyValue
                newProperties = existingProperties
            } else {
                newProperties[name] = propertyValue
            }
            if let currentRawTile {
                self.currentRawTile = RawTile(id: currentRawTile.id, properties: newProperties)
            } else if let currentTiledObject {
                self.currentTiledObject = MSKTiledObject(id: currentTiledObject.id,
                                                         name: currentTiledObject.name,
                                                         x: currentTiledObject.x,
                                                         y: currentTiledObject.y,
                                                         properties: newProperties,
                                                         polygon: currentTiledObject.polygon)
            } else if let currentTiledObjectGroup {
                self.currentTiledObjectGroup = MSKTiledObjectGroup(id: currentTiledObjectGroup.id,
                                                                   name: currentTiledObjectGroup.name,
                                                                   properties: newProperties,
                                                                   objects: nil)
            }
        } else if elementName == ElementName.layer.rawValue {
            guard let layerWidth = getDoubleValueFromAttributes(attributeDict, attributeName: .width),
                  let layerHeight = getDoubleValueFromAttributes(attributeDict, attributeName: .height) else {
                log(logLevel: .error, message: "Layer found without a size definition: LINE[\(parser.lineNumber)]")
                parser.abortParsing()
                return
            }
            if mapSize.width != layerWidth || mapSize.height != layerHeight {
                log(logLevel: .error, message: "Layer found with a different size (\(layerWidth),\(layerHeight) than defined on the map (\(mapSize)): LINE[\(parser.lineNumber)]")
                parser.abortParsing()
                return
            }
            guard
                let id = getIntValueFromAttributes(attributeDict, attributeName: .id),
                let name = getStringValueFromAttributes(attributeDict, attributeName: .name)
            else {
                log(logLevel: .error, message: "Invalid layer (no name or id) found: LINE[\(parser.lineNumber)]")
                parser.abortParsing()
                return
            }
            var invisible = false
            if let visible = getStringValueFromAttributes(attributeDict, attributeName: .visible),
               visible == "0" {
                invisible = true
            }
            currentRawLayer = .init(id: id, name: name, invisible: invisible)
        } else if elementName == ElementName.data.rawValue {
            if let encoding = getStringValueFromAttributes(attributeDict, attributeName: .encoding) {
                if let encodingType = EncodingType.init(rawValue: encoding) {
                    self.encodingType = encodingType
                } else {
                    log(logLevel: .error, message: "Unsupported encoding found (only csv is supported): LINE[\(parser.lineNumber)]")
                    parser.abortParsing()
                }
            } else {
                log(logLevel: .warning, message: "No encoding found, defaulting to csv")
                self.encodingType = .csv
            }
        } else if elementName == ElementName.objectgroup.rawValue {
            guard let id = getStringValueFromAttributes(attributeDict, attributeName: .id),
                  let name = getStringValueFromAttributes(attributeDict, attributeName: .name) else {
                log(logLevel: .error, message: "Objectgroup id and/ or name not present: LINE[\(parser.lineNumber)]")
                parser.abortParsing()
                return
            }
            currentTiledObjectGroup = .init(id: id, name: name, properties: nil, objects: nil)
        } else if elementName == ElementName.object.rawValue {
            // swiftlint:disable identifier_name
            guard let id = getStringValueFromAttributes(attributeDict, attributeName: .id),
                    let x = getDoubleValueFromAttributes(attributeDict, attributeName: .x),
                    let y = getDoubleValueFromAttributes(attributeDict, attributeName: .y)   else {
                log(logLevel: .error, message: "Object id and/ or x/ y not present: LINE[\(parser.lineNumber)]")
                parser.abortParsing()
                return
            }
            let parsedName = getStringValueFromAttributes(attributeDict, attributeName: .name)
            let name = parsedName == nil ? UUID().uuidString : parsedName!
            // swiftlint:enable identifier_name
            currentTiledObject = .init(id: id, name: name, x: Int(x), y: Int(y), properties: nil, polygon: nil)
        } else if elementName == ElementName.polygon.rawValue {
            if let points = getStringValueFromAttributes(attributeDict, attributeName: .points), let currentTiledObject {
                let commaSeparatedValues = points.split(separator: " ")
                let coords: [CGPoint] = commaSeparatedValues.map { commaSeparatedValue in
                    let values = commaSeparatedValue.split(separator: ",")
                    guard values.count == 2, let xValue = Double(String(values[0])), let yValue = Double(String(values[1])) else {
                        fatalError("invalid polygon points found: LINE[\(parser.lineNumber)]")
                    }
                    return .init(x: xValue, y: -yValue)
                }
                self.currentTiledObject = MSKTiledObject(id: currentTiledObject.id,
                                                         name: currentTiledObject.name,
                                                         x: currentTiledObject.x,
                                                         y: currentTiledObject.y,
                                                         properties: currentTiledObject.properties,
                                                         polygon: .init(points: coords))
            }
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public func parser(_ parser: XMLParser,
                       didEndElement elementName: String,
                       namespaceURI: String?,
                       qualifiedName qName: String?) {
        if elementName == ElementName.tile.rawValue {
            currentRawTile = nil
        } else if elementName == ElementName.tileset.rawValue {
            currentRawTileSet = nil
        } else if elementName == ElementName.properties.rawValue {
            if let currentRawTile {
                rawTiles.append(currentRawTile)
            }
        } else if elementName == ElementName.layer.rawValue {
            currentRawLayer = nil
        } else if elementName == ElementName.object.rawValue {
            if let currentTiledObject {
                guard let currentTiledObjectGroup else {
                    return
                }
                var existingObjects = currentTiledObjectGroup.objects
                if var existingObjects {
                    existingObjects.append(currentTiledObject)
                    self.currentTiledObjectGroup = .init(id: currentTiledObjectGroup.id,
                                                         name: currentTiledObjectGroup.name,
                                                         properties: currentTiledObjectGroup.properties,
                                                         objects: existingObjects)
                } else {
                    existingObjects = [currentTiledObject]
                    self.currentTiledObjectGroup = .init(id: currentTiledObjectGroup.id,
                                                         name: currentTiledObjectGroup.name,
                                                         properties: currentTiledObjectGroup.properties,
                                                         objects: existingObjects)
                }
            }
            currentTiledObject = nil
        } else if elementName == ElementName.objectgroup.rawValue {
            if let currentTiledObjectGroup {
                tiledObjectGroups.append(currentTiledObjectGroup)
            }
            currentTiledObjectGroup = nil
        } else if elementName == ElementName.data.rawValue {
            guard let currentRawLayer = currentRawLayer else {
                log(logLevel: .warning, message: "Data is only supported on layers")
                return
            }
            if encodingType == .csv { // not functional, but good to have in place for future support
                characters = characters.replacingOccurrences(of: "\n", with: "")
                characters = characters.trimmingCharacters(in: .whitespacesAndNewlines)
                characters = characters.replacingOccurrences(of: " ", with: "")
                let layerData = characters.components(separatedBy: ",").compactMap { Int($0) }

                createTileGroupsFor(layerData: layerData)

                if let addingCustomTileGroups {
                    tileGroups.append(contentsOf: addingCustomTileGroups)
                }

                let tileSet = SKTileSet(tileGroups: tileGroups, tileSetType: .grid)
                layers.append(.init(tileSet: tileSet,
                                    layerData: layerData,
                                    rawLayer: currentRawLayer))
            }
        }
        characters = ""
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        characters += string
    }

    private func createTileGroupsFor(layerData: [Int]) {
        let uniqueTiles = Array(Set(layerData))
        for tileId in uniqueTiles {
            if !hasValidTileData(tileId: tileId) || hasTileGroupForTile(tileId: tileId) {
                continue
            }
            if let tileGroup = getTileGroup(tileId: tileId) {
                tileGroups.append(tileGroup)
            }
        }
    }

    // swiftlint:disable:next large_tuple
    private func parseTileIdWithFlags(tileId: UInt32) -> (gid: UInt32,
                                                          flipHorizontal: Bool,
                                                          flipVertical: Bool,
                                                          flipDiagonal: Bool) {
        let flippedDiagonalFlag: UInt32   = 0x20000000
        let flippedVerticalFlag: UInt32   = 0x40000000
        let flippedHorizontalFlag: UInt32 = 0x80000000

        let flippedAll = (flippedHorizontalFlag | flippedVerticalFlag | flippedDiagonalFlag)
        let flippedMask = ~(flippedAll)

        let flipHorizontal = (tileId & flippedHorizontalFlag) != 0
        let flipVertical = (tileId & flippedVerticalFlag) != 0
        let flipDiagonal = (tileId & flippedDiagonalFlag) != 0

        // get the actual gid from the mask
        let gid = tileId & flippedMask
        return (gid, flipHorizontal, flipVertical, flipDiagonal)
    }

    private func hasValidTileData(tileId: Int) -> Bool {
        return tileId > 0
    }

    private func hasTileGroupForTile(tileId: Int) -> Bool {
        return tileGroups.first { $0.name == ("\(tileId)") } != nil
    }

    private func getRawTileSetFor(tileId: Int) -> RawTileSet? {
        for rawTileSet in rawTileSets {
            if tileId >= rawTileSet.firstGid && tileId < rawTileSet.firstGid+rawTileSet.tileCount {
                return rawTileSet
            }
        }
        log(logLevel: .error, message: "getRawTileSetFor not found for tileId \(tileId)")
        return nil
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func getTileGroup(tileId: Int) -> SKTileGroup? {
        let tileGroup = tileGroups.first { $0.name == ("\(tileId)") }
        if let tileGroup = tileGroup {
            return tileGroup
        }
        let tileInfo = parseTileIdWithFlags(tileId: UInt32(tileId))
        // Determine correct gid first, corrected for bitflags
        guard let rawTileSet = getRawTileSetFor(tileId: Int(tileInfo.gid)) else {
            return nil
        }

        let tileIdInSheet = Int(tileInfo.gid)-rawTileSet.firstGid
        let tileSheet = rawTileSet.image
        let sourceTexture = SKTexture(imageNamed: tileSheet)

        var column = 0
        if tileIdInSheet > 0 {
            column = tileIdInSheet%rawTileSet.columns
        }
        let row = Int(floor(CGFloat(tileIdInSheet)/CGFloat(rawTileSet.columns)))

        let tileTexture = SKTexture(rect: CGRect(x: tileSize.width*CGFloat(column)/sourceTexture.size().width,
                                                 y: 1-(tileSize.height*CGFloat(row+1)/sourceTexture.size().height),
                                                 width: tileSize.width/sourceTexture.size().width,
                                                 height: tileSize.height/sourceTexture.size().height),
                                    in: sourceTexture)

        let tileDefinition = SKTileDefinition(texture: tileTexture)
        if let rawTile = rawTiles.first(where: { $0.id == tileId }), let properties = rawTile.properties {
            tileDefinition.userData = .init()
            properties.forEach { (key: String, value: Any) in
                tileDefinition.userData?.setValue(value, forKey: key)
            }
        }
        if tileInfo.flipDiagonal {
            if tileInfo.flipHorizontal && !tileInfo.flipVertical {
                tileDefinition.rotation = .rotation270
            } else if tileInfo.flipHorizontal && tileInfo.flipVertical {
                tileDefinition.rotation = .rotation90
                tileDefinition.flipHorizontally = true
            } else if !tileInfo.flipHorizontal && tileInfo.flipVertical {
                tileDefinition.rotation = .rotation90
            } else if !tileInfo.flipHorizontal && !tileInfo.flipVertical {
                tileDefinition.rotation = .rotation270
                tileDefinition.flipHorizontally = true
            }
        } else {
            tileDefinition.flipVertically = tileInfo.flipVertical
            tileDefinition.flipHorizontally = tileInfo.flipHorizontal
        }

        let newTileGroup = SKTileGroup(tileDefinition: tileDefinition)
        let currentSize = tileDefinition.size
        tileDefinition.size = .init(width: currentSize.width*1.01, height: currentSize.height*1.01)
        newTileGroup.name = "\(tileId)"
        return newTileGroup
    }

    private func getIntValueFromAttributes(_ attributes: [String: String], attributeName: AttributeName) -> Int? {
        guard let value = attributes[attributeName.rawValue], let integerValue = Int(value) else {
            return nil
        }
        return integerValue
    }

    private func getDoubleValueFromAttributes(_ attributes: [String: String], attributeName: AttributeName) -> Double? {
        guard let value = attributes[attributeName.rawValue], let doubleValue = Double(value) else {
            return nil
        }
        return doubleValue
    }

    private func getStringValueFromAttributes(_ attributes: [String: String], attributeName: AttributeName) -> String? {
        return attributes[attributeName.rawValue]
    }
}

private enum EncodingType: String {
    case csv
}

private enum ElementName: String {
    case map
    case tileset
    case image
    case property
    case properties
    case tile
    case polygon
    case layer
    case data
    case object
    case objectgroup
}
// swiftlint:disable identifier_name
private enum AttributeName: String {
    case width
    case height
    case tilewidth
    case tileheight
    case firstgid
    case tilecount
    case columns
    case source
    case id
    case points
    case name
    case x
    case y
    case value
    case encoding
    case type
    case visible
}

private struct RawTileSet {
    let firstGid: Int
    let tileCount: Int
    let image: String
    let columns: Int
}

private struct RawTile {
    let id: Int
    let properties: [String: Any]?
}

private enum PropertyType: String {
    case string
    case bool
    case int
}

private struct RawLayer {
    let id: Int
    let name: String
    let invisible: Bool
}
// swiftlint:disable:next file_length
// swiftlint:enable identifier_name
