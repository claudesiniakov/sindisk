import Foundation
import CoreGraphics

// MARK: - Treemap

public struct TreemapTile: Sendable {
    public let node: FileNode
    public let rect: CGRect
    public let level: Int
    /// Индекс ветки первого уровня (для раскраски).
    public let branch: Int
    /// Папка, внутри которой разложены её дети (рисуется рамкой с заголовком).
    public let isContainer: Bool
}

public enum Treemap {
    /// Squarified treemap (Bruls, Huizing, van Wijk). Значения в порядке убывания;
    /// возвращает прямоугольники в том же порядке. Нулевые значения получают `.zero`.
    public static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: values.count)
        let indices = values.indices.filter { values[$0] > 0 }
        let total = indices.reduce(0.0) { $0 + values[$1] }
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }
        let scale = Double(rect.width * rect.height) / total
        var remaining = rect
        var i = 0

        while i < indices.count {
            guard remaining.width > 0.0001, remaining.height > 0.0001 else { break }
            let side = Double(min(remaining.width, remaining.height))
            var row: [Int] = []
            var rowSum = 0.0, rowMin = Double.infinity, rowMax = 0.0
            var best = Double.infinity
            var j = i
            while j < indices.count {
                let a = values[indices[j]] * scale
                let sum = rowSum + a
                let mn = min(rowMin, a), mx = max(rowMax, a)
                let worst = max(side * side * mx / (sum * sum), (sum * sum) / (side * side * mn))
                if row.isEmpty || worst <= best {
                    row.append(indices[j])
                    rowSum = sum
                    rowMin = mn
                    rowMax = mx
                    best = worst
                    j += 1
                } else {
                    break
                }
            }

            if remaining.width >= remaining.height {
                let w = CGFloat(rowSum / Double(remaining.height))
                var y = remaining.minY
                for k in row {
                    let h = CGFloat(values[k] * scale) / w
                    result[k] = CGRect(x: remaining.minX, y: y, width: w, height: h)
                    y += h
                }
                remaining = CGRect(x: remaining.minX + w, y: remaining.minY,
                                   width: max(0, remaining.width - w), height: remaining.height)
            } else {
                let h = CGFloat(rowSum / Double(remaining.width))
                var x = remaining.minX
                for k in row {
                    let w = CGFloat(values[k] * scale) / h
                    result[k] = CGRect(x: x, y: remaining.minY, width: w, height: h)
                    x += w
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + h,
                                   width: remaining.width, height: max(0, remaining.height - h))
            }
            i = j
        }
        return result
    }

    /// Вложенная раскладка: папки раскрываются внутрь, пока плитка достаточно велика
    /// (не глубже `levels`), — как в классических картах диска.
    public static func tiles(
        for root: FileNode,
        in rect: CGRect,
        levels: Int = 4,
        header: CGFloat = 20,
        minContainer: CGSize = CGSize(width: 90, height: 56)
    ) -> [TreemapTile] {
        var out: [TreemapTile] = []
        func visit(_ node: FileNode, _ area: CGRect, _ level: Int, _ branch: Int?) {
            let kids = Array(node.children.lazy.filter { $0.size > 0 }.prefix(400))
            let rects = squarify(kids.map { Double($0.size) }, in: area)
            for (index, pair) in zip(kids, rects).enumerated() {
                let (kid, r) = pair
                guard r.width >= 2, r.height >= 2 else { continue }
                let b = branch ?? index
                let container = level < levels && kid.isDirectory && !kid.children.isEmpty
                    && r.width >= minContainer.width && r.height >= minContainer.height
                out.append(TreemapTile(node: kid, rect: r, level: level, branch: b, isContainer: container))
                if container {
                    let inner = CGRect(x: r.minX + 3, y: r.minY + header, width: r.width - 6, height: r.height - header - 3)
                    visit(kid, inner, level + 1, b)
                }
            }
        }
        visit(root, rect, 1, nil)
        return out
    }
}

// MARK: - Sunburst

public struct SunburstArc: Sendable {
    public let node: FileNode
    /// Кольцо: 1 — ближайшее к центру.
    public let depth: Int
    /// Углы в радианах от 0 до 2π, отсчёт от «12 часов» по часовой стрелке.
    public let start: Double
    public let end: Double
    /// Индекс ветки первого уровня (для раскраски).
    public let branch: Int
    /// > 0 — сегмент «Прочее», объединяющий столько мелких элементов папки `node`.
    public let otherCount: Int

    public var isOther: Bool { otherCount > 0 }
}

public enum Sunburst {
    public static func layout(root: FileNode, maxDepth: Int = 6, minAngle: Double = 0.006) -> [SunburstArc] {
        var arcs: [SunburstArc] = []
        func visit(_ node: FileNode, depth: Int, start: Double, end: Double, branch: Int?) {
            guard depth <= maxDepth, node.size > 0 else { return }
            let span = end - start
            var a = start
            var index = 0
            let kids = node.children
            while index < kids.count {
                let c = kids[index]
                if c.size <= 0 { index += 1; continue }
                let w = span * Double(c.size) / Double(node.size)
                if w < minAngle { break }
                let b = branch ?? index
                arcs.append(SunburstArc(node: c, depth: depth, start: a, end: a + w, branch: b, otherCount: 0))
                if c.isDirectory { visit(c, depth: depth + 1, start: a, end: a + w, branch: b) }
                a += w
                index += 1
            }
            let rest = kids.count - index
            if rest > 0, end - a > 0.002 {
                arcs.append(SunburstArc(node: node, depth: depth, start: a, end: end, branch: branch ?? index, otherCount: rest))
            }
        }
        visit(root, depth: 1, start: 0, end: 2 * .pi, branch: nil)
        return arcs
    }

    /// Поиск сегмента под точкой. `angle` — радианы от «12 часов» по часовой стрелке.
    public static func hit(_ arcs: [SunburstArc], depth: Int, angle: Double) -> SunburstArc? {
        arcs.first { $0.depth == depth && angle >= $0.start && angle < $0.end }
    }
}
