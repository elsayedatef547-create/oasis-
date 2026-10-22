import Foundation
import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CoreXLSX

// MARK: - UTType & FileDocument

extension UTType {
    static var excelXLSX: UTType {
        UTType(filenameExtension: "xlsx")
            ?? UTType("org.openxmlformats.spreadsheetml.sheet")
            ?? .data
    }
}

struct XLSXDocument: FileDocument {
    static var readableContentTypes: [UTType] { [UTType.excelXLSX] }
    static var writableContentTypes: [UTType] { [UTType.excelXLSX] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Errors

enum XLSXError: LocalizedError {
    case unreadable
    case empty

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "تعذّر قراءة ملف Excel. تأكد من أن الصيغة XLSX."
        case .empty:
            return "الملف لا يحتوي على بيانات."
        }
    }
}

// MARK: - Service

enum XLSXService {

    // MARK: Import

    static func readEntries(from data: Data) throws -> [InventoryEntry] {
        let file: XLSXFile
        do {
            file = try XLSXFile(data: data)
        } catch {
            throw XLSXError.unreadable
        }

        let sharedStrings = try? file.parseSharedStrings()
        let paths: [String]
        do {
            paths = try file.parseWorksheetPaths()
        } catch {
            throw XLSXError.unreadable
        }

        var table: [[Int: String]] = []

        for path in paths {
            guard let worksheet = try? file.parseWorksheet(at: path) else { continue }
            guard let rows = worksheet.data?.rows, !rows.isEmpty else { continue }

            var parsedRows: [[Int: String]] = []
            for row in rows {
                var values: [Int: String] = [:]
                for cell in row.cells {
                    let index = columnIndex(from: cell.reference.column.value)
                    let text = cellText(cell, shared: sharedStrings).trimmed
                    if !text.isEmpty {
                        values[index] = text
                    }
                }
                if !values.isEmpty {
                    parsedRows.append(values)
                }
            }

            if !parsedRows.isEmpty {
                table = parsedRows
                break
            }
        }

        if table.isEmpty {
            throw XLSXError.empty
        }

        var map = ColumnMap(name: 0, code: 1, sku: nil, qty: 2, price: 3, cost: nil)
        var dataRows = table
        var headerDetected = false

        if let detected = detectColumns(in: table[0]) {
            map = detected
            dataRows = Array(table.dropFirst())
            headerDetected = true
        }

        func cleanCode(_ raw: String) -> String {
            var value = raw.trimmed
            if value.hasSuffix(".0"), Double(value.dropLast(2)) != nil {
                value = String(value.dropLast(2))
            }
            return value
        }

        var entries: [InventoryEntry] = []
        for row in dataRows {
            if !headerDetected, let qtyColumn = map.qty, let qtyText = row[qtyColumn], qtyText.parsedDouble == nil {
                continue
            }

            let name = map.name.flatMap { row[$0] } ?? ""
            let code = cleanCode(map.code.flatMap { row[$0] } ?? "")
            let sku = cleanCode(map.sku.flatMap { row[$0] } ?? "")
            let qtyValue = (map.qty.flatMap { row[$0] } ?? "").parsedDouble
            let price = (map.price.flatMap { row[$0] } ?? "").parsedDouble ?? 0
            let cost = (map.cost.flatMap { row[$0] } ?? "").parsedDouble ?? 0

            if name.trimmed.isEmpty && code.isEmpty && sku.isEmpty { continue }

            var entry = InventoryEntry(name: name, code: code, qty: qtyValue ?? 0, price: price, cost: cost)
            entry.sku = sku
            entry.hasQty = qtyValue != nil
            entries.append(entry)
        }

        if entries.isEmpty {
            throw XLSXError.empty
        }
        return entries
    }

    private static func cellText(_ cell: Cell, shared: SharedStrings?) -> String {
        if let inline = cell.inlineString?.text {
            return inline
        }
        if cell.type == .sharedString, let shared = shared, let text = cell.stringValue(shared) {
            return text
        }
        return cell.value ?? ""
    }

    private static func columnIndex(from letters: String) -> Int {
        var index = 0
        for scalar in letters.uppercased().unicodeScalars where scalar.value >= 65 && scalar.value <= 90 {
            index = index * 26 + Int(scalar.value - 64)
        }
        return max(index - 1, 0)
    }

    private struct ColumnMap {
        var name: Int?
        var code: Int?
        var sku: Int?
        var qty: Int?
        var price: Int?
        var cost: Int?
    }

    private static func detectColumns(in row: [Int: String]) -> ColumnMap? {
        let costKeys = ["cost", "costo", "coste", "التكلفة", "تكلفة", "سعر الشراء"]
        let qtyKeys = ["الكمية", "كمية", "العدد", "qty", "quantity", "existencias", "stock", "cantidad", "unidades", "uds"]
        let priceKeys = ["السعر", "سعر", "price", "unit_price", "precio", "pvp"]
        let codeKeys = ["الكود", "كود", "باركود", "الباركود", "رمز", "code", "barcode", "código", "codigo", "ean"]
        let skuKeys = ["sku", "internal reference", "referencia", "reference", "المرجع", "مرجع"]
        let nameKeys = ["الاسم", "اسم", "الصنف", "البند", "المنتج", "name", "product", "item", "description", "nombre", "producto", "artículo", "articulo"]
        let typeKeys = ["type", "tipo", "نوع"]

        var map = ColumnMap()

        for index in row.keys.sorted() {
            let header = (row[index] ?? "").lowercased().trimmed
            if header.isEmpty { continue }
            if typeKeys.contains(where: { header.contains($0) }) { continue }

            if map.cost == nil, costKeys.contains(where: { header.contains($0) }) {
                map.cost = index
            } else if map.qty == nil, qtyKeys.contains(where: { header.contains($0) }) {
                map.qty = index
            } else if map.price == nil, priceKeys.contains(where: { header.contains($0) }) {
                map.price = index
            } else if map.code == nil, codeKeys.contains(where: { header.contains($0) }) {
                map.code = index
            } else if map.sku == nil, skuKeys.contains(where: { header.contains($0) }) {
                map.sku = index
            } else if map.name == nil, nameKeys.contains(where: { header.contains($0) }) {
                map.name = index
            }
        }

        // لو مفيش عمود باركود، المرجع الداخلي (SKU) هو الكود.
        if map.code == nil, let sku = map.sku {
            map.code = sku
            map.sku = nil
        }

        if map.name == nil && map.code == nil {
            return nil
        }
        return map
    }

    // MARK: Export

    static func makeWorkbook(products: [Product]) -> Data {
        let headers = ["الاسم", "الكود", "SKU", "الكمية", "السعر", "التكلفة"]

        var rowsXML = ""

        var headerCells = ""
        let columnLetters = ["A", "B", "C", "D", "E", "F"]
        for (index, title) in headers.enumerated() {
            headerCells += inlineStringCell(reference: "\(columnLetters[index])1", text: title)
        }
        rowsXML += "<row r=\"1\">\(headerCells)</row>"

        for (offset, product) in products.enumerated() {
            let rowNumber = offset + 2
            var cells = ""
            cells += inlineStringCell(reference: "A\(rowNumber)", text: product.name)
            cells += inlineStringCell(reference: "B\(rowNumber)", text: product.code)
            cells += inlineStringCell(reference: "C\(rowNumber)", text: product.sku)
            cells += numberCell(reference: "D\(rowNumber)", value: product.qty)
            cells += numberCell(reference: "E\(rowNumber)", value: product.price)
            cells += numberCell(reference: "F\(rowNumber)", value: product.cost)
            rowsXML += "<row r=\"\(rowNumber)\">\(cells)</row>"
        }

        let sheetXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetViews><sheetView rightToLeft="1" workbookViewId="0"/></sheetViews><cols><col min="1" max="1" width="42" customWidth="1"/><col min="2" max="2" width="22" customWidth="1"/><col min="3" max="3" width="16" customWidth="1"/><col min="4" max="4" width="12" customWidth="1"/><col min="5" max="5" width="14" customWidth="1"/><col min="6" max="6" width="14" customWidth="1"/></cols><sheetData>\(rowsXML)</sheetData></worksheet>
        """

        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>
        """

        let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """

        let workbook = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Inventory" sheetId="1" r:id="rId1"/></sheets></workbook>
        """

        let workbookRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
        """

        let entries: [(name: String, data: Data)] = [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rootRels.utf8)),
            ("xl/workbook.xml", Data(workbook.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(workbookRels.utf8)),
            ("xl/worksheets/sheet1.xml", Data(sheetXML.utf8))
        ]

        return ZipWriter.archive(entries: entries)
    }

    private static func inlineStringCell(reference: String, text: String) -> String {
        "<c r=\"\(reference)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlEscape(text))</t></is></c>"
    }

    private static func numberCell(reference: String, value: Double) -> String {
        let safeValue = value.isFinite ? value : 0
        return "<c r=\"\(reference)\"><v>\(safeValue)</v></c>"
    }

    private static func xmlEscape(_ text: String) -> String {
        var output = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&":
                output += "&amp;"
            case "<":
                output += "&lt;"
            case ">":
                output += "&gt;"
            case "\"":
                output += "&quot;"
            case "'":
                output += "&apos;"
            default:
                let value = scalar.value
                if value == 0x9 || value == 0xA || value == 0xD || value >= 0x20 {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        return output
    }
}

// MARK: - Minimal ZIP writer (stored entries)

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { buffer in
            self.append(contentsOf: buffer)
        }
    }
}

private enum ZipWriter {
    private static let crcTable: [UInt32] = {
        var table: [UInt32] = []
        table.reserveCapacity(256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                if (c & 1) != 0 {
                    c = 0xEDB88320 ^ (c >> 1)
                } else {
                    c = c >> 1
                }
            }
            table.append(c)
        }
        return table
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = crcTable[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    static func archive(entries: [(name: String, data: Data)]) -> Data {
        var output = Data()
        var central = Data()
        var count: UInt16 = 0

        for entry in entries {
            let nameData = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(output.count)

            // Local file header
            output.appendLE(UInt32(0x04034B50))
            output.appendLE(UInt16(20))
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0x21))
            output.appendLE(crc)
            output.appendLE(size)
            output.appendLE(size)
            output.appendLE(UInt16(nameData.count))
            output.appendLE(UInt16(0))
            output.append(nameData)
            output.append(entry.data)

            // Central directory header
            central.appendLE(UInt32(0x02014B50))
            central.appendLE(UInt16(20))
            central.appendLE(UInt16(20))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0x21))
            central.appendLE(crc)
            central.appendLE(size)
            central.appendLE(size)
            central.appendLE(UInt16(nameData.count))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt32(0))
            central.appendLE(offset)
            central.append(nameData)

            count += 1
        }

        let centralOffset = UInt32(output.count)
        let centralSize = UInt32(central.count)
        output.append(central)

        // End of central directory record
        output.appendLE(UInt32(0x06054B50))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(count)
        output.appendLE(count)
        output.appendLE(centralSize)
        output.appendLE(centralOffset)
        output.appendLE(UInt16(0))

        return output
    }
}
