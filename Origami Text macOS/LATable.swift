//
//  LATable.swift
//  OrigamiText
//
//  The data model for an inline table, copied verbatim from Author's
//  LiquidAuthorTextCore so the reader shares the exact model and formula
//  grammar the exporter writes. It decodes the Visual-Meta `tables` array
//  directly; Origami Text stores tables as a value type (LiquidDoc.Table)
//  for its Sendable/Hashable document model and bridges to LATable here
//  for the interactive path (edit a cell → recalculate()).
//
//  A cell keeps both a raw literal `value` and an optional `formula` so the
//  table round-trips "live" (data + functions). For a read-only reader the
//  precomputed `value` is enough; recalculate() drives an editable one.
//

import Foundation

public struct LATableCell: Codable, Equatable {
    /// The literal/entered text, or the last computed result when `formula` is set.
    public var value: String
    /// An optional spreadsheet formula (e.g. "=SUM(A1:A3)").
    public var formula: String?

    public init(value: String = "", formula: String? = nil) {
        self.value = value
        self.formula = formula
    }
}

public final class LATable: Codable {

    public private(set) var identifier: String
    public private(set) var rowCount: Int
    public private(set) var columnCount: Int
    /// Row-major grid: `cells[row][column]`.
    public private(set) var cells: [[LATableCell]]

    public init(identifier: String = UUID().uuidString, rows: Int = 3, columns: Int = 3) {
        self.identifier = identifier
        let rows = max(1, rows)
        let columns = max(1, columns)
        self.rowCount = rows
        self.columnCount = columns
        self.cells = (0..<rows).map { _ in (0..<columns).map { _ in LATableCell() } }
    }

    // MARK: - Access

    public func isValid(row: Int, column: Int) -> Bool {
        row >= 0 && row < rowCount && column >= 0 && column < columnCount
    }

    public func cell(row: Int, column: Int) -> LATableCell {
        guard isValid(row: row, column: column) else { return LATableCell() }
        return cells[row][column]
    }

    public func setValue(_ value: String, row: Int, column: Int) {
        guard isValid(row: row, column: column) else { return }
        cells[row][column].value = value
    }

    public func setFormula(_ formula: String?, row: Int, column: Int) {
        guard isValid(row: row, column: column) else { return }
        cells[row][column].formula = formula
    }

    // MARK: - Structure editing

    public func insertRow(at index: Int) {
        let clamped = min(max(0, index), rowCount)
        cells.insert((0..<columnCount).map { _ in LATableCell() }, at: clamped)
        rowCount += 1
    }

    public func appendRow() {
        insertRow(at: rowCount)
    }

    public func removeRow(at index: Int) {
        guard rowCount > 1, index >= 0, index < rowCount else { return }
        cells.remove(at: index)
        rowCount -= 1
    }

    public func insertColumn(at index: Int) {
        let clamped = min(max(0, index), columnCount)
        for row in 0..<rowCount {
            cells[row].insert(LATableCell(), at: clamped)
        }
        columnCount += 1
    }

    public func appendColumn() {
        insertColumn(at: columnCount)
    }

    public func removeColumn(at index: Int) {
        guard columnCount > 1, index >= 0, index < columnCount else { return }
        for row in 0..<rowCount {
            cells[row].remove(at: index)
        }
        columnCount -= 1
    }

    // MARK: - Spreadsheet-style references (used by the UI and formulas)

    /// Spreadsheet column label for a zero-based column index: 0 -> "A", 25 -> "Z", 26 -> "AA".
    public static func columnLabel(for index: Int) -> String {
        var index = index
        var label = ""
        repeat {
            let remainder = index % 26
            label = String(UnicodeScalar(65 + remainder)!) + label
            index = index / 26 - 1
        } while index >= 0
        return label
    }

    /// A1-style reference for a cell, e.g. row 0 / column 0 -> "A1".
    public static func reference(row: Int, column: Int) -> String {
        "\(columnLabel(for: column))\(row + 1)"
    }
}

// MARK: - Formulas

public extension LATable {

    /// Applies user input to a cell: a leading "=" marks a formula (whose result
    /// is produced by `recalculate()`); anything else is a literal value.
    func setInput(_ input: String, row: Int, column: Int) {
        guard isValid(row: row, column: column) else { return }
        if input.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("=") {
            cells[row][column].formula = input.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            cells[row][column].formula = nil
            cells[row][column].value = input
        }
    }

    /// The text to show when editing a cell: its formula if it has one, otherwise
    /// the literal/last-computed value.
    func editingInput(row: Int, column: Int) -> String {
        let cell = cell(row: row, column: column)
        if let formula = cell.formula, !formula.isEmpty { return formula }
        return cell.value
    }

    /// True if the cell holds a formula.
    func hasFormula(row: Int, column: Int) -> Bool {
        let cell = cell(row: row, column: column)
        return (cell.formula?.hasPrefix("=")) ?? false
    }

    /// Recomputes every formula cell's `value`, in place — resolving cell
    /// references, ranges and the supported functions, with cycle detection.
    func recalculate() {
        LATableCalculator(table: self).recalculateAll()
    }
}

// MARK: - Formula evaluation

private enum LAFormulaError: Error {
    case syntax, reference, cycle, name, divideByZero, notAvailable, number

    var display: String {
        switch self {
        case .syntax: return "#SYNTAX!"
        case .reference: return "#REF!"
        case .cycle: return "#CYCLE!"
        case .name: return "#NAME!"
        case .divideByZero: return "#DIV/0!"
        case .notAvailable: return "#N/A"
        case .number: return "#NUM!"
        }
    }
}

private enum LAFormulaToken: Equatable {
    case number(Double)
    case cell(row: Int, column: Int)
    case ident(String)
    case plus, minus, star, slash, lparen, rparen, comma, colon
}

/// Evaluates a table's formulas. References resolve through `numericValue`, which
/// memoizes results and tracks an in-progress set to detect cycles.
private final class LATableCalculator {

    private let table: LATable
    private enum Cached { case value(Double?); case failure(LAFormulaError) }
    private var cache: [Int: Cached] = [:]
    private var visiting: Set<Int> = []

    init(table: LATable) { self.table = table }

    func recalculateAll() {
        for row in 0..<table.rowCount {
            for column in 0..<table.columnCount {
                let cell = table.cell(row: row, column: column)
                guard let formula = cell.formula, formula.hasPrefix("=") else { continue }
                do {
                    let result = try numericValue(row: row, column: column) ?? 0
                    table.setValue(LATableCalculator.format(result), row: row, column: column)
                } catch let error as LAFormulaError {
                    table.setValue(error.display, row: row, column: column)
                } catch {
                    table.setValue(LAFormulaError.syntax.display, row: row, column: column)
                }
            }
        }
    }

    private func key(_ row: Int, _ column: Int) -> Int { row * max(1, table.columnCount) + column }

    /// Numeric value of a cell: nil for blank/non-numeric literals; throws for
    /// formula errors (including cycles).
    fileprivate func numericValue(row: Int, column: Int) throws -> Double? {
        guard table.isValid(row: row, column: column) else { throw LAFormulaError.reference }
        let k = key(row, column)
        if let cached = cache[k] {
            switch cached {
            case .value(let value): return value
            case .failure(let error): throw error
            }
        }

        let cell = table.cell(row: row, column: column)
        guard let formula = cell.formula, formula.hasPrefix("=") else {
            let value = Double(cell.value.trimmingCharacters(in: .whitespacesAndNewlines))
            cache[k] = .value(value)
            return value
        }

        if visiting.contains(k) {
            cache[k] = .failure(.cycle)
            throw LAFormulaError.cycle
        }
        visiting.insert(k)
        defer { visiting.remove(k) }

        do {
            let tokens = try LATableCalculator.tokenize(String(formula.dropFirst()))
            var parser = LAFormulaParser(tokens: tokens, calculator: self)
            let result = try parser.parse()
            cache[k] = .value(result)
            return result
        } catch let error as LAFormulaError {
            cache[k] = .failure(error)
            throw error
        }
    }

    /// A cell reference used in arithmetic: blank/non-numeric reads as 0.
    fileprivate func scalar(row: Int, column: Int) throws -> Double {
        return (try numericValue(row: row, column: column)) ?? 0
    }

    /// The numeric values in a rectangular range (non-numeric cells skipped).
    fileprivate func rangeValues(_ r1: Int, _ c1: Int, _ r2: Int, _ c2: Int) throws -> [Double] {
        guard table.isValid(row: r1, column: c1), table.isValid(row: r2, column: c2) else {
            throw LAFormulaError.reference
        }
        var values: [Double] = []
        for row in min(r1, r2)...max(r1, r2) {
            for column in min(c1, c2)...max(c1, c2) {
                if let value = try numericValue(row: row, column: column) { values.append(value) }
            }
        }
        return values
    }

    // MARK: Formatting

    static func format(_ value: Double) -> String {
        if value.isNaN { return LAFormulaError.number.display }
        if value.isInfinite { return LAFormulaError.divideByZero.display }
        if value == value.rounded() && abs(value) < 1e15 { return String(Int64(value)) }
        return String(format: "%g", value)
    }

    // MARK: Tokenizer

    /// Bijective base-26 column index for a letter label ("A" -> 0, "AA" -> 26).
    static func columnIndex(fromLabel label: String) -> Int? {
        guard !label.isEmpty else { return nil }
        var result = 0
        for character in label {
            guard let ascii = character.asciiValue else { return nil }
            let upper = (ascii >= 97 && ascii <= 122) ? ascii - 32 : ascii
            guard upper >= 65, upper <= 90 else { return nil }
            result = result * 26 + Int(upper - 64)
        }
        return result - 1
    }

    static func tokenize(_ string: String) throws -> [LAFormulaToken] {
        var tokens: [LAFormulaToken] = []
        let characters = Array(string)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character == " " || character == "\t" || character == "\n" || character == "\r" {
                index += 1
                continue
            }
            switch character {
            case "+": tokens.append(.plus); index += 1
            case "-": tokens.append(.minus); index += 1
            case "*": tokens.append(.star); index += 1
            case "/": tokens.append(.slash); index += 1
            case "(": tokens.append(.lparen); index += 1
            case ")": tokens.append(.rparen); index += 1
            case ",": tokens.append(.comma); index += 1
            case ":": tokens.append(.colon); index += 1
            default:
                if character.isLetter {
                    var letters = ""
                    while index < characters.count && characters[index].isLetter {
                        letters.append(characters[index]); index += 1
                    }
                    if index < characters.count && characters[index].isNumber {
                        var digits = ""
                        while index < characters.count && characters[index].isNumber {
                            digits.append(characters[index]); index += 1
                        }
                        guard let column = columnIndex(fromLabel: letters),
                              let rowNumber = Int(digits), rowNumber >= 1 else {
                            throw LAFormulaError.reference
                        }
                        tokens.append(.cell(row: rowNumber - 1, column: column))
                    } else {
                        tokens.append(.ident(letters))
                    }
                } else if character.isNumber || character == "." {
                    var number = ""
                    while index < characters.count && (characters[index].isNumber || characters[index] == ".") {
                        number.append(characters[index]); index += 1
                    }
                    guard let value = Double(number) else { throw LAFormulaError.syntax }
                    tokens.append(.number(value))
                } else {
                    throw LAFormulaError.syntax
                }
            }
        }
        return tokens
    }
}

/// Recursive-descent parser: expr → term (('+'|'-') term)*, term → factor
/// (('*'|'/') factor)*, factor → number | cellRef | function(args) | (expr) | -factor.
/// Ranges (A1:B3) are only valid as function arguments.
private struct LAFormulaParser {

    let tokens: [LAFormulaToken]
    var position = 0
    let calculator: LATableCalculator

    mutating func parse() throws -> Double {
        let value = try parseExpression()
        guard position == tokens.count else { throw LAFormulaError.syntax }
        return value
    }

    func peek(_ offset: Int = 0) -> LAFormulaToken? {
        let index = position + offset
        return index < tokens.count ? tokens[index] : nil
    }

    @discardableResult
    mutating func advance() -> LAFormulaToken? {
        guard position < tokens.count else { return nil }
        defer { position += 1 }
        return tokens[position]
    }

    mutating func parseExpression() throws -> Double {
        var value = try parseTerm()
        while let token = peek() {
            if token == .plus { advance(); value += try parseTerm() }
            else if token == .minus { advance(); value -= try parseTerm() }
            else { break }
        }
        return value
    }

    mutating func parseTerm() throws -> Double {
        var value = try parseFactor()
        while let token = peek() {
            if token == .star { advance(); value *= try parseFactor() }
            else if token == .slash {
                advance()
                let divisor = try parseFactor()
                if divisor == 0 { throw LAFormulaError.divideByZero }
                value /= divisor
            } else { break }
        }
        return value
    }

    mutating func parseFactor() throws -> Double {
        guard let token = peek() else { throw LAFormulaError.syntax }
        switch token {
        case .minus:
            advance(); return -(try parseFactor())
        case .plus:
            advance(); return try parseFactor()
        case .number(let value):
            advance(); return value
        case .lparen:
            advance()
            let value = try parseExpression()
            guard case .rparen? = peek() else { throw LAFormulaError.syntax }
            advance()
            return value
        case .cell(let row, let column):
            advance()
            return try calculator.scalar(row: row, column: column)
        case .ident(let name):
            advance()
            guard case .lparen? = peek() else { throw LAFormulaError.name }
            advance()
            var values: [Double] = []
            if case .rparen? = peek() {
                // no arguments
            } else {
                values.append(contentsOf: try parseArgument())
                while case .comma? = peek() {
                    advance()
                    values.append(contentsOf: try parseArgument())
                }
            }
            guard case .rparen? = peek() else { throw LAFormulaError.syntax }
            advance()
            return try apply(function: name, values: values)
        default:
            throw LAFormulaError.syntax
        }
    }

    mutating func parseArgument() throws -> [Double] {
        if case .cell(let r1, let c1)? = peek(), case .colon? = peek(1) {
            advance()   // first cell
            advance()   // colon
            guard case .cell(let r2, let c2)? = peek() else { throw LAFormulaError.syntax }
            advance()
            return try calculator.rangeValues(r1, c1, r2, c2)
        }
        return [try parseExpression()]
    }

    func apply(function: String, values: [Double]) throws -> Double {
        switch function.uppercased() {
        case "SUM": return values.reduce(0, +)
        case "AVERAGE":
            guard !values.isEmpty else { throw LAFormulaError.divideByZero }
            return values.reduce(0, +) / Double(values.count)
        case "MIN":
            guard let minimum = values.min() else { throw LAFormulaError.notAvailable }
            return minimum
        case "MAX":
            guard let maximum = values.max() else { throw LAFormulaError.notAvailable }
            return maximum
        case "COUNT": return Double(values.count)
        default: throw LAFormulaError.name
        }
    }
}
