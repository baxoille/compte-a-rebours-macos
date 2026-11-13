import CoreGraphics
import Foundation

struct GridInsets: Codable, Equatable {
    var horizontal: CGFloat = 0
    var vertical: CGFloat = 0
}

struct CountdownGrid {
    private struct Lattice {
        let columns: Int
        let rows: Int
        let stepX: CGFloat
        let stepY: CGFloat
        let tileWidth: CGFloat
        let tileHeight: CGFloat
        let sideColumns: Int
        let outerRows: Int
        let surplus: Int
        let score: CGFloat
    }

    private struct Cell: Hashable {
        let row: Int
        let column: Int
    }

    static func tiles(in size: CGSize, around panel: CGRect, count: Int, insets: GridInsets) -> [CGRect] {
        guard size.width > 0, size.height > 0, count > 0 else { return [] }
        let insetX = min(size.width * 0.25, max(size.width * 0.033, insets.horizontal))
        let insetY = min(size.height * 0.25, max(size.height * 0.041, insets.vertical))
        let width = size.width - 2 * insetX
        let height = size.height - 2 * insetY
        let gutter = min(13, min(width, height) * 0.03)
        let reserveWidth = min(width, panel.width + 2 * gutter)
        let reserveHeight = min(height, panel.height + 2 * gutter)
        let openFraction = 1 - reserveWidth * reserveHeight / (width * height)
        guard openFraction > 0 else { return [] }

        let ratio: CGFloat = 1.48
        let targetColumns = sqrt(CGFloat(count) / openFraction * width / height * ratio)
        let columnsCenter = min(count + 4, max(2, Int(targetColumns.rounded())))
        let spread = max(4, Int(ceil(CGFloat(columnsCenter) * 0.18)))
        let rowSearchMargin = max(6, Int(ceil(min(64, 2 / openFraction))))
        var best: Lattice?

        for columns in max(2, columnsCenter - spread)...(columnsCenter + spread) {
            let targetRows = CGFloat(count) / (CGFloat(columns) * openFraction)
            let rowsCenter = max(2, Int(ceil(targetRows)))
            let stepX = width / CGFloat(columns)
            for rows in max(2, rowsCenter - 5)...(rowsCenter + rowSearchMargin) {
                let stepY = height / CGFloat(rows)
                let tileWidth = min(stepX * 0.81, stepY * 0.84 / ratio)
                let tileHeight = tileWidth * ratio
                let sideColumns = max(0, Int(floor((width - reserveWidth - tileWidth) / (2 * stepX) + 0.5)))
                let outerRows = max(0, Int(floor((height - reserveHeight - tileHeight) / (2 * stepY) + 0.5)))
                let capacity = columns * rows - (columns - 2 * sideColumns) * (rows - 2 * outerRows)
                guard capacity >= count else { continue }
                let surplus = capacity - count
                let missingBand = count >= 8 && (sideColumns == 0 || outerRows == 0)
                let score = CGFloat(surplus) + 14 * abs(log(stepY / stepX / ratio)) + (missingBand ? 20 : 0)
                if score < (best?.score ?? .infinity) {
                    best = Lattice(columns: columns, rows: rows, stepX: stepX, stepY: stepY,
                                   tileWidth: tileWidth, tileHeight: tileHeight,
                                   sideColumns: sideColumns, outerRows: outerRows, surplus: surplus, score: score)
                }
            }
        }
        guard let best else { return [] }

        var cells: [Cell] = []
        for row in 0..<best.rows {
            for column in 0..<best.columns {
                if min(column, best.columns - column - 1) < best.sideColumns ||
                    min(row, best.rows - row - 1) < best.outerRows {
                    cells.append(Cell(row: row, column: column))
                }
            }
        }
        let trimmed: Set<Cell> = best.surplus == 0 ? [] : Set(cells.sorted {
            cornerOrder($0, in: best) < cornerOrder($1, in: best)
        }.prefix(best.surplus))
        return cells.compactMap { cell in
            guard !trimmed.contains(cell) else { return nil }
            return CGRect(x: insetX + (CGFloat(cell.column) + 0.5) * best.stepX - best.tileWidth / 2,
                          y: insetY + (CGFloat(cell.row) + 0.5) * best.stepY - best.tileHeight / 2,
                          width: best.tileWidth, height: best.tileHeight)
        }
    }

    private static func cornerOrder(_ cell: Cell, in lattice: Lattice) -> (Int, Int, Int, Int) {
        let side = min(cell.column, lattice.columns - cell.column - 1)
        let end = min(cell.row, lattice.rows - cell.row - 1)
        let lower = cell.row * 2 >= lattice.rows
        let right = cell.column * 2 >= lattice.columns
        let corner = lower ? (right ? 1 : 3) : (right ? 2 : 0)
        return (side + end, corner, end, side)
    }
}
