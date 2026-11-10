import Foundation

/// Descompresor DEFLATE (RFC 1951) en Swift puro, adaptado del algoritmo de referencia «puff» (zlib, dominio público).
/// Existe para leer DOCX y XLSX (que son ZIP) sin añadir dependencias y con los mismos resultados en cualquier plataforma.
enum Inflate {
    enum Failure: Error, Equatable { case invalid(String), tooLarge }

    private struct Huffman {
        var count = [Int](repeating: 0, count: 16)
        var symbol: [Int]

        /// Devuelve el sobrante de códigos: 0 = completo, <0 = sobresuscrito, >0 = incompleto.
        init(lengths: [Int]) {
            symbol = [Int](repeating: 0, count: lengths.count)
            for length in lengths { count[length] += 1 }
            var left = 1
            for len in 1..<16 {
                left <<= 1
                left -= count[len]
            }
            leftover = left
            var offsets = [Int](repeating: 0, count: 16)
            for len in 1..<15 { offsets[len + 1] = offsets[len] + count[len] }
            for (index, length) in lengths.enumerated() where length != 0 {
                symbol[offsets[length]] = index
                offsets[length] += 1
            }
        }
        var leftover = 0
    }

    private struct Reader {
        let data: [UInt8]
        var position: Int
        let end: Int
        var bitBuffer: UInt32 = 0
        var bitCount = 0

        init(data: [UInt8], start: Int, end: Int) {
            self.data = data
            self.position = start
            self.end = end
        }

        mutating func bits(_ need: Int) throws -> Int {
            var value = bitBuffer
            while bitCount < need {
                guard position < end else { throw Failure.invalid("datos truncados") }
                value |= UInt32(data[position]) << UInt32(bitCount)
                position += 1
                bitCount += 8
            }
            bitBuffer = value >> UInt32(need)
            bitCount -= need
            return Int(value & ((UInt32(1) << UInt32(need)) - 1))
        }

        mutating func decode(_ huffman: Huffman) throws -> Int {
            var code = 0
            var first = 0
            var index = 0
            for len in 1..<16 {
                code |= try bits(1)
                let count = huffman.count[len]
                if code - count < first { return huffman.symbol[index + (code - first)] }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            throw Failure.invalid("código Huffman no válido")
        }
    }

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    /// Descomprime `input[start..<end]`. Falla si el resultado supera `maxOutput` (protección contra bombas de compresión).
    static func inflate(_ input: [UInt8], start: Int, end: Int, maxOutput: Int) throws -> [UInt8] {
        var reader = Reader(data: input, start: start, end: end)
        var output: [UInt8] = []
        output.reserveCapacity(min(maxOutput, max(1024, (end - start) * 4)))

        var last = 0
        repeat {
            last = try reader.bits(1)
            let type = try reader.bits(2)
            switch type {
            case 0:
                reader.bitBuffer = 0
                reader.bitCount = 0
                guard reader.position + 4 <= reader.end else { throw Failure.invalid("bloque sin compresión truncado") }
                let length = Int(input[reader.position]) | (Int(input[reader.position + 1]) << 8)
                let complement = Int(input[reader.position + 2]) | (Int(input[reader.position + 3]) << 8)
                guard length == (~complement & 0xFFFF) else { throw Failure.invalid("longitud de bloque incoherente") }
                reader.position += 4
                guard reader.position + length <= reader.end else { throw Failure.invalid("bloque sin compresión truncado") }
                guard output.count + length <= maxOutput else { throw Failure.tooLarge }
                output.append(contentsOf: input[reader.position..<(reader.position + length)])
                reader.position += length
            case 1:
                try codes(&reader, &output, literals: fixedLiterals, distances: fixedDistances, maxOutput: maxOutput)
            case 2:
                let (literals, distances) = try dynamicTables(&reader)
                try codes(&reader, &output, literals: literals, distances: distances, maxOutput: maxOutput)
            default:
                throw Failure.invalid("tipo de bloque no válido")
            }
        } while last == 0
        return output
    }

    private static let fixedLiterals: Huffman = {
        var lengths = [Int](repeating: 8, count: 288)
        for index in 144..<256 { lengths[index] = 9 }
        for index in 256..<280 { lengths[index] = 7 }
        return Huffman(lengths: lengths)
    }()
    private static let fixedDistances: Huffman = Huffman(lengths: [Int](repeating: 5, count: 30))

    private static func dynamicTables(_ reader: inout Reader) throws -> (Huffman, Huffman) {
        let literalCount = try reader.bits(5) + 257
        let distanceCount = try reader.bits(5) + 1
        let codeLengthCount = try reader.bits(4) + 4
        guard literalCount <= 286, distanceCount <= 30 else { throw Failure.invalid("tablas dinámicas no válidas") }
        let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        var lengths = [Int](repeating: 0, count: 19)
        for index in 0..<codeLengthCount { lengths[order[index]] = try reader.bits(3) }
        let codeLengths = Huffman(lengths: lengths)
        guard codeLengths.leftover == 0 else { throw Failure.invalid("tabla de longitudes incompleta") }

        var all = [Int](repeating: 0, count: literalCount + distanceCount)
        var index = 0
        while index < literalCount + distanceCount {
            let symbol = try reader.decode(codeLengths)
            if symbol < 16 {
                all[index] = symbol
                index += 1
            } else {
                var previous = 0
                var repeatCount = 0
                if symbol == 16 {
                    guard index > 0 else { throw Failure.invalid("repetición sin longitud previa") }
                    previous = all[index - 1]
                    repeatCount = 3 + (try reader.bits(2))
                } else if symbol == 17 {
                    repeatCount = 3 + (try reader.bits(3))
                } else {
                    repeatCount = 11 + (try reader.bits(7))
                }
                guard index + repeatCount <= literalCount + distanceCount else { throw Failure.invalid("demasiadas longitudes") }
                for _ in 0..<repeatCount {
                    all[index] = previous
                    index += 1
                }
            }
        }
        guard all[256] != 0 else { throw Failure.invalid("falta el código de fin de bloque") }
        let literals = Huffman(lengths: Array(all[0..<literalCount]))
        let distances = Huffman(lengths: Array(all[literalCount..<(literalCount + distanceCount)]))
        return (literals, distances)
    }

    private static func codes(_ reader: inout Reader, _ output: inout [UInt8], literals: Huffman, distances: Huffman, maxOutput: Int) throws {
        while true {
            var symbol = try reader.decode(literals)
            if symbol < 256 {
                guard output.count < maxOutput else { throw Failure.tooLarge }
                output.append(UInt8(symbol))
            } else if symbol == 256 {
                return
            } else {
                symbol -= 257
                guard symbol < 29 else { throw Failure.invalid("símbolo de longitud no válido") }
                let length = lengthBase[symbol] + (try reader.bits(lengthExtra[symbol]))
                let distanceSymbol = try reader.decode(distances)
                guard distanceSymbol < 30 else { throw Failure.invalid("símbolo de distancia no válido") }
                let distance = distBase[distanceSymbol] + (try reader.bits(distExtra[distanceSymbol]))
                guard distance <= output.count else { throw Failure.invalid("referencia anterior al inicio") }
                guard output.count + length <= maxOutput else { throw Failure.tooLarge }
                var from = output.count - distance
                for _ in 0..<length {
                    output.append(output[from])
                    from += 1
                }
            }
        }
    }
}

/// CRC-32 (el mismo que usa ZIP), para detectar archivos dañados.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = (value & 1) != 0 ? (0xEDB88320 ^ (value >> 1)) : (value >> 1) }
        return value
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }
}

/// Lector de archivos ZIP (los DOCX y XLSX lo son). Solo lectura, sin ZIP64 ni cifrado, con límites de seguridad.
public struct ZipArchive {
    public struct Entry: Equatable {
        public let name: String
        let method: Int
        let compressedSize: Int
        public let uncompressedSize: Int
        let localHeaderOffset: Int
        let crc: UInt32
    }

    public enum Failure: Error, Equatable {
        case notAZip
        case encrypted
        case unsupported(String)
        case unsafe(String)
        case corrupt(String)
    }

    public let entries: [Entry]
    private let bytes: [UInt8]

    public init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw Failure.notAZip }
        // Registro de fin del directorio central: se busca desde el final (puede llevar un comentario de hasta 65 535 bytes).
        var eocd = -1
        var index = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 65_535)
        while index >= lowest {
            if bytes[index] == 0x50, bytes[index + 1] == 0x4B, bytes[index + 2] == 0x05, bytes[index + 3] == 0x06 { eocd = index; break }
            index -= 1
        }
        guard eocd >= 0 else { throw Failure.notAZip }
        let total = Self.u16(bytes, eocd + 10)
        let centralSize = Self.u32(bytes, eocd + 12)
        let centralOffset = Self.u32(bytes, eocd + 16)
        if total == 0xFFFF || centralSize == 0xFFFF_FFFF || centralOffset == 0xFFFF_FFFF { throw Failure.unsupported("ZIP64") }
        guard total <= AttachmentLimits.maxZipEntries else { throw Failure.unsafe("demasiadas entradas (\(total))") }
        guard centralOffset + centralSize <= bytes.count else { throw Failure.corrupt("directorio central fuera del archivo") }

        var parsed: [Entry] = []
        var position = centralOffset
        var declaredTotal = 0
        for _ in 0..<total {
            guard position + 46 <= bytes.count, Self.u32(bytes, position) == 0x0201_4B50 else { throw Failure.corrupt("directorio central dañado") }
            let flags = Self.u16(bytes, position + 8)
            let method = Self.u16(bytes, position + 10)
            let crc = UInt32(Self.u32(bytes, position + 16))
            let compressed = Self.u32(bytes, position + 20)
            let uncompressed = Self.u32(bytes, position + 24)
            let nameLength = Self.u16(bytes, position + 28)
            let extraLength = Self.u16(bytes, position + 30)
            let commentLength = Self.u16(bytes, position + 32)
            let offset = Self.u32(bytes, position + 42)
            guard position + 46 + nameLength <= bytes.count else { throw Failure.corrupt("nombre fuera del archivo") }
            if flags & 0x1 != 0 { throw Failure.encrypted }
            if compressed == 0xFFFF_FFFF || uncompressed == 0xFFFF_FFFF || offset == 0xFFFF_FFFF { throw Failure.unsupported("ZIP64") }
            let nameBytes = Array(bytes[(position + 46)..<(position + 46 + nameLength)])
            let name = String(decoding: nameBytes, as: UTF8.self)
            guard uncompressed <= AttachmentLimits.maxZipEntryBytes else { throw Failure.unsafe("entrada de \(uncompressed) bytes") }
            declaredTotal += uncompressed
            guard declaredTotal <= AttachmentLimits.maxZipTotalBytes else { throw Failure.unsafe("contenido total demasiado grande") }
            parsed.append(Entry(name: name, method: method, compressedSize: compressed, uncompressedSize: uncompressed,
                                localHeaderOffset: offset, crc: crc))
            position += 46 + nameLength + extraLength + commentLength
        }
        self.entries = parsed
        self.bytes = bytes
    }

    public func entry(named name: String) -> Entry? {
        entries.first { $0.name == name }
    }

    /// Lee y descomprime una entrada, comprobando tamaño y CRC.
    public func read(_ entry: Entry) throws -> Data {
        let offset = entry.localHeaderOffset
        guard offset + 30 <= bytes.count, Self.u32(bytes, offset) == 0x0403_4B50 else { throw Failure.corrupt("cabecera local dañada") }
        let nameLength = Self.u16(bytes, offset + 26)
        let extraLength = Self.u16(bytes, offset + 28)
        let start = offset + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard start >= 0, end <= bytes.count else { throw Failure.corrupt("datos fuera del archivo") }

        let output: [UInt8]
        switch entry.method {
        case 0:
            output = Array(bytes[start..<end])
        case 8:
            do {
                output = try Inflate.inflate(bytes, start: start, end: end, maxOutput: entry.uncompressedSize)
            } catch Inflate.Failure.tooLarge {
                throw Failure.unsafe("«\(entry.name)» se expande más de lo declarado")
            } catch Inflate.Failure.invalid(let reason) {
                throw Failure.corrupt("«\(entry.name)»: \(reason)")
            }
        default:
            throw Failure.unsupported("método de compresión \(entry.method)")
        }
        guard output.count == entry.uncompressedSize else { throw Failure.corrupt("«\(entry.name)» no mide lo declarado") }
        guard CRC32.checksum(output) == entry.crc else { throw Failure.corrupt("«\(entry.name)» no pasa la verificación (CRC)") }
        return Data(output)
    }

    public func data(named name: String) throws -> Data? {
        guard let entry = entry(named: name) else { return nil }
        return try read(entry)
    }

    private static func u16(_ bytes: [UInt8], _ index: Int) -> Int {
        Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
    }

    private static func u32(_ bytes: [UInt8], _ index: Int) -> Int {
        Int(bytes[index]) | (Int(bytes[index + 1]) << 8) | (Int(bytes[index + 2]) << 16) | (Int(bytes[index + 3]) << 24)
    }
}
