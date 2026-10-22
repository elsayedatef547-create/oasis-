import UIKit
import Foundation

enum PDFGenerator {
    private static let pageRect = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
    private static let margin: CGFloat = 36
    private static let bottomReserve: CGFloat = 48
    private static let cellPadding: CGFloat = 4

    private static let accent = UIColor(red: 0.31, green: 0.27, blue: 0.90, alpha: 1)
    private static let softFill = UIColor(red: 0.93, green: 0.93, blue: 0.99, alpha: 1)
    private static let altFill = UIColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1)
    private static let lineColor = UIColor(red: 0.85, green: 0.85, blue: 0.89, alpha: 1)
    private static let textColor = UIColor(red: 0.10, green: 0.10, blue: 0.14, alpha: 1)
    private static let mutedColor = UIColor(red: 0.42, green: 0.42, blue: 0.48, alpha: 1)

    private static let bodyFont = UIFont.systemFont(ofSize: 11)
    private static let boldFont = UIFont.boldSystemFont(ofSize: 11)
    private static let codeFont = UIFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .regular)

    // Columns are laid out visually from right to left: index, name, code, qty, sale price, total.
    // سعر الشراء مش بيظهر في الفاتورة نهائيًا.
    private static let columnWidths: [CGFloat] = [26, 190, 90, 50, 80, 87]
    private static let headerTitles: [String] = ["#", "الصنف", "الكود", "الكمية", "سعر البيع", "الإجمالي"]

    private static var contentWidth: CGFloat {
        pageRect.width - margin * 2
    }

    // MARK: Public API

    static func generate(for invoice: Invoice, salePrice: (InvoiceItem) -> Double? = { _ in nil }, items customItems: [InvoiceItem]? = nil) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: invoice.title,
            kCGPDFContextCreator as String: "Invoice Scanner"
        ]

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)
        let items = (customItems ?? invoice.items).sorted { $0.sortIndex < $1.sortIndex }
        // إجمالي الفاتورة = مجموع (الكمية × سعر البيع) لكل صنف، وعدد القطع = مجموع الكميات.
        let totalSale = items.reduce(0) { partial, item in
            partial + item.qty * (salePrice(item) ?? 0)
        }
        let pieceCount = items.reduce(0) { $0 + max($1.qty, 0) }
        let notes = invoice.notes.trimmed

        return renderer.pdfData { context in
            var pageNumber = 1
            context.beginPage()

            var y = drawHeader(invoice: invoice)
            y = drawTableHeader(at: y)

            for (index, item) in items.enumerated() {
                let height = rowHeight(for: item)
                if y + height > pageRect.height - bottomReserve {
                    drawFooter(page: pageNumber)
                    context.beginPage()
                    pageNumber += 1
                    y = drawTableHeader(at: margin)
                }
                drawRow(item, index: index, at: y, height: height, salePrice: salePrice(item))
                y += height
            }

            let notesHeight: CGFloat = notes.isEmpty ? 0 : (textHeight(notes, width: contentWidth, font: bodyFont) + 30)
            let totalsHeight: CGFloat = 90 + notesHeight

            if y + totalsHeight > pageRect.height - bottomReserve {
                drawFooter(page: pageNumber)
                context.beginPage()
                pageNumber += 1
                y = margin
            }

            drawTotals(at: y + 14, pieceCount: pieceCount, total: totalSale, notes: notes)
            drawFooter(page: pageNumber)
        }
    }

    static func writeTemporaryFile(for invoice: Invoice, salePrice: (InvoiceItem) -> Double? = { _ in nil }, items: [InvoiceItem]? = nil) throws -> URL {
        let data = generate(for: invoice, salePrice: salePrice, items: items)
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        var safeName = invoice.title
            .components(separatedBy: forbidden)
            .joined(separator: "-")
            .trimmed
        if safeName.isEmpty {
            safeName = "invoice"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName).pdf")
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: Drawing helpers

    private static func attributes(
        font: UIFont,
        color: UIColor,
        alignment: NSTextAlignment,
        wrap: Bool = true
    ) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.baseWritingDirection = .rightToLeft
        style.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
        return [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ]
    }

    private static func draw(
        _ text: String,
        in rect: CGRect,
        font: UIFont,
        color: UIColor,
        alignment: NSTextAlignment = .right,
        wrap: Bool = true
    ) {
        let attrs = attributes(font: font, color: color, alignment: alignment, wrap: wrap)
        (text as NSString).draw(in: rect, withAttributes: attrs)
    }

    private static func textHeight(_ text: String, width: CGFloat, font: UIFont) -> CGFloat {
        let attrs = attributes(font: font, color: textColor, alignment: .right)
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs,
            context: nil
        )
        return ceil(bounds.height)
    }

    private static func columnRect(_ index: Int, y: CGFloat, height: CGFloat) -> CGRect {
        var right = pageRect.width - margin
        for i in 0..<index {
            right -= columnWidths[i]
        }
        let width = columnWidths[index]
        return CGRect(x: right - width, y: y, width: width, height: height)
    }

    private static func fill(_ rect: CGRect, color: UIColor, cornerRadius: CGFloat = 0) {
        color.setFill()
        if cornerRadius > 0 {
            UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius).fill()
        } else {
            UIBezierPath(rect: rect).fill()
        }
    }

    private static func line(from start: CGPoint, to end: CGPoint, color: UIColor, width: CGFloat = 0.6) {
        let path = UIBezierPath()
        path.move(to: start)
        path.addLine(to: end)
        path.lineWidth = width
        color.setStroke()
        path.stroke()
    }

    // MARK: Sections

    private static func drawHeader(invoice: Invoice) -> CGFloat {
        fill(CGRect(x: 0, y: 0, width: pageRect.width, height: 10), color: accent)

        draw(
            "فاتورة",
            in: CGRect(x: margin, y: 28, width: contentWidth, height: 32),
            font: UIFont.boldSystemFont(ofSize: 26),
            color: accent
        )

        var y: CGFloat = 66
        draw(
            invoice.title,
            in: CGRect(x: margin, y: y, width: contentWidth, height: 20),
            font: UIFont.boldSystemFont(ofSize: 14),
            color: textColor,
            wrap: false
        )
        y += 24

        if !invoice.supplier.trimmed.isEmpty {
            draw(
                "المورد: \(invoice.supplier.trimmed)",
                in: CGRect(x: margin, y: y, width: contentWidth, height: 16),
                font: bodyFont,
                color: mutedColor,
                wrap: false
            )
            y += 18
        }

        draw(
            "التاريخ: \(Formatters.date(invoice.date))",
            in: CGRect(x: margin, y: y, width: contentWidth, height: 16),
            font: bodyFont,
            color: mutedColor,
            wrap: false
        )
        y += 18

        line(
            from: CGPoint(x: margin, y: y + 6),
            to: CGPoint(x: pageRect.width - margin, y: y + 6),
            color: lineColor,
            width: 1
        )

        return y + 18
    }

    private static func drawTableHeader(at y: CGFloat) -> CGFloat {
        let height: CGFloat = 28
        fill(CGRect(x: margin, y: y, width: contentWidth, height: height), color: accent, cornerRadius: 6)

        for index in 0..<columnWidths.count {
            let rect = columnRect(index, y: y + 7, height: height - 7)
                .insetBy(dx: cellPadding, dy: 0)
            let alignment: NSTextAlignment = (index == 1) ? .right : .center
            draw(headerTitles[index], in: rect, font: boldFont, color: .white, alignment: alignment, wrap: false)
        }
        return y + height
    }

    private static func rowHeight(for item: InvoiceItem) -> CGFloat {
        let nameWidth = columnWidths[1] - cellPadding * 2
        let name = item.name.isEmpty ? "-" : item.name
        let height = textHeight(name, width: nameWidth, font: bodyFont)
        return max(28, height + 14)
    }

    private static func drawRow(_ item: InvoiceItem, index: Int, at y: CGFloat, height: CGFloat, salePrice: Double?) {
        if index % 2 == 1 {
            fill(CGRect(x: margin, y: y, width: contentWidth, height: height), color: altFill)
        }

        let textTop = y + 7
        let textHeightValue = height - 10

        let lineTotal = item.qty * (salePrice ?? 0)
        let values: [String] = [
            String(index + 1),
            item.name.isEmpty ? "-" : item.name,
            item.code,
            Formatters.number(item.qty, maxFraction: 3),
            salePrice.map { Formatters.number($0, minFraction: 2) } ?? "-",
            salePrice == nil ? "-" : Formatters.number(lineTotal, minFraction: 2)
        ]

        for column in 0..<columnWidths.count {
            let rect = columnRect(column, y: textTop, height: textHeightValue)
                .insetBy(dx: cellPadding, dy: 0)
            let alignment: NSTextAlignment = (column == 1) ? .right : .center
            let font = (column == 5 || column == 4) ? boldFont : (column == 2 ? codeFont : bodyFont)
            let wrap = (column == 1)
            draw(values[column], in: rect, font: font, color: textColor, alignment: alignment, wrap: wrap)
        }

        line(
            from: CGPoint(x: margin, y: y + height),
            to: CGPoint(x: pageRect.width - margin, y: y + height),
            color: lineColor
        )
    }

    private static func drawTotals(at y: CGFloat, pieceCount: Double, total: Double, notes: String) {
        let boxWidth: CGFloat = 230
        let boxRect = CGRect(x: margin, y: y, width: boxWidth, height: 66)
        fill(boxRect, color: softFill, cornerRadius: 10)

        let labelRect1 = CGRect(x: boxRect.minX + 12, y: boxRect.minY + 10, width: boxWidth - 24, height: 16)
        draw("عدد القطع", in: labelRect1, font: bodyFont, color: mutedColor, alignment: .right, wrap: false)
        draw(Formatters.number(pieceCount, maxFraction: 3), in: labelRect1, font: boldFont, color: textColor, alignment: .left, wrap: false)

        let labelRect2 = CGRect(x: boxRect.minX + 12, y: boxRect.minY + 34, width: boxWidth - 24, height: 22)
        draw("إجمالي الفاتورة", in: labelRect2, font: UIFont.boldSystemFont(ofSize: 13), color: textColor, alignment: .right, wrap: false)
        draw(
            Formatters.number(total, minFraction: 2),
            in: labelRect2,
            font: UIFont.boldSystemFont(ofSize: 15),
            color: accent,
            alignment: .left,
            wrap: false
        )

        if !notes.isEmpty {
            let notesTop = boxRect.maxY + 16
            draw(
                "ملاحظات",
                in: CGRect(x: margin, y: notesTop, width: contentWidth, height: 16),
                font: boldFont,
                color: textColor,
                wrap: false
            )
            let height = textHeight(notes, width: contentWidth, font: bodyFont)
            draw(
                notes,
                in: CGRect(x: margin, y: notesTop + 18, width: contentWidth, height: height + 4),
                font: bodyFont,
                color: mutedColor
            )
        }
    }

    private static func drawFooter(page: Int) {
        let y = pageRect.height - 30
        line(
            from: CGPoint(x: margin, y: y - 6),
            to: CGPoint(x: pageRect.width - margin, y: y - 6),
            color: lineColor
        )
        draw(
            "صفحة \(page)",
            in: CGRect(x: margin, y: y, width: contentWidth, height: 14),
            font: UIFont.systemFont(ofSize: 9),
            color: mutedColor,
            alignment: .center,
            wrap: false
        )
    }
}
