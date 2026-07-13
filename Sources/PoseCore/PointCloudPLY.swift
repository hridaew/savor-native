import Foundation

public struct RGBColor: Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public struct PointCloudPoint: Equatable, Sendable {
    public let position: Vector3
    public let color: RGBColor

    public init(position: Vector3, color: RGBColor) {
        self.position = position
        self.color = color
    }
}

public enum PointCloudPLYEncoder {
    public static func encode(points: [PointCloudPoint]) -> Data {
        var text = """
        ply
        format ascii 1.0
        element vertex \(points.count)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        end_header

        """
        for point in points {
            text += "\(point.position.x) \(point.position.y) \(point.position.z) "
            text += "\(point.color.red) \(point.color.green) \(point.color.blue)\n"
        }
        return Data(text.utf8)
    }
}

public enum PLYHeaderReader {
    public enum Error: Swift.Error {
        case missingVertexCount
    }

    public static func vertexCount(in data: Data) throws -> Int {
        let prefix = data.prefix(4_096)
        let header = String(decoding: prefix, as: UTF8.self)
        for line in header.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ")
            if fields.count == 3,
               fields[0] == "element",
               fields[1] == "vertex",
               let count = Int(fields[2])
            {
                return count
            }
        }
        throw Error.missingVertexCount
    }
}
