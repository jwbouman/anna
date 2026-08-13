//
//  ContentView.swift
//  anna : stock analyzer
//
//  Created by Jan Bouman on 11/08/2026.
//

import Charts
import Foundation
import Observation
import SwiftUI

struct StockPrice: Identifiable {
    let id = UUID()
    let date: Date
    let close: Double
    let volume: Int
    let rsi: Double?
    let stochasticK: Double?
    let stochasticD: Double?
}

@MainActor
@Observable
final class StockPriceViewModel {
    private(set) var prices: [StockPrice] = []
    private(set) var symbol = "ADYEN.AS"
    private(set) var historicalDayCount = 30
    private(set) var isLoading = false
    var errorMessage: String?

    private let service = YahooFinanceService()

    var latestPrice: StockPrice? {
        prices.last
    }

    var priceChange: Double? {
        guard let first = prices.first?.close, let last = prices.last?.close else {
            return nil
        }

        return last - first
    }

    func loadPrices(symbol requestedSymbol: String? = nil, dayCount requestedDayCount: Int? = nil) async {
        let normalizedSymbol = (requestedSymbol ?? symbol)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let normalizedDayCount = min(max(requestedDayCount ?? historicalDayCount, 15), 90)

        guard !normalizedSymbol.isEmpty else {
            prices = []
            errorMessage = "Vul een ticker-symbool in, bijvoorbeeld ADYEN.AS of AAPL."
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            prices = try await service.fetchLastClosingPrices(symbol: normalizedSymbol, count: normalizedDayCount)
            symbol = normalizedSymbol
            historicalDayCount = normalizedDayCount
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

struct YahooFinanceService {
    func fetchLastClosingPrices(symbol: String, count: Int) async throws -> [StockPrice] {
        guard let encodedSymbol = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw StockPriceError.invalidURL
        }

        var components = URLComponents(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encodedSymbol)")
        components?.queryItems = [
            URLQueryItem(name: "range", value: rangeParameter(for: count)),
            URLQueryItem(name: "interval", value: "1d")
        ]

        guard let url = components?.url else {
            throw StockPriceError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw StockPriceError.badResponse
        }

        let chartResponse = try JSONDecoder().decode(YahooChartResponse.self, from: data)

        guard let result = chartResponse.chart.result.first,
              let timestamps = result.timestamp,
              let quote = result.indicators.quote.first else {
            throw StockPriceError.noData
        }

        let entries = zip(timestamps, zip(zip(quote.close, quote.high), zip(quote.low, quote.volume))).compactMap { timestamp, values -> (date: Date, close: Double, high: Double, low: Double, volume: Int)? in
            let ((close, high), (low, volume)) = values

            guard let close, let high, let low, let volume else {
                return nil
            }

            return (
                date: Date(timeIntervalSince1970: TimeInterval(timestamp)),
                close: close,
                high: high,
                low: low,
                volume: volume
            )
        }

        let rsiValues = calculateRSI(for: entries.map(\.close), period: 14)
        let stochasticValues = calculateStochasticOscillator(entries: entries, period: 14, signalPeriod: 3)
        let prices = entries.enumerated().map { index, entry in
            StockPrice(
                date: entry.date,
                close: entry.close,
                volume: entry.volume,
                rsi: rsiValues[index],
                stochasticK: stochasticValues[index].k,
                stochasticD: stochasticValues[index].d
            )
        }

        return Array(prices.suffix(count))
    }

    private func rangeParameter(for count: Int) -> String {
        count <= 45 ? "3mo" : "6mo"
    }

    private func calculateStochasticOscillator(
        entries: [(date: Date, close: Double, high: Double, low: Double, volume: Int)],
        period: Int,
        signalPeriod: Int
    ) -> [(k: Double?, d: Double?)] {
        guard entries.count >= period else {
            return Array(repeating: (nil, nil), count: entries.count)
        }

        var kValues = Array<Double?>(repeating: nil, count: entries.count)
        var dValues = Array<Double?>(repeating: nil, count: entries.count)

        for index in (period - 1)..<entries.count {
            let window = entries[(index - period + 1)...index]
            guard let lowestLow = window.map(\.low).min(),
                  let highestHigh = window.map(\.high).max() else {
                continue
            }

            if highestHigh == lowestLow {
                kValues[index] = 50
            } else {
                kValues[index] = ((entries[index].close - lowestLow) / (highestHigh - lowestLow)) * 100
            }
        }

        for index in (period - 1)..<entries.count {
            let signalStartIndex = max(0, index - signalPeriod + 1)
            let signalValues = kValues[signalStartIndex...index].compactMap { $0 }

            guard signalValues.count == signalPeriod else {
                continue
            }

            dValues[index] = signalValues.reduce(0, +) / Double(signalPeriod)
        }

        return zip(kValues, dValues).map { (k: $0, d: $1) }
    }

    private func calculateRSI(for closes: [Double], period: Int) -> [Double?] {
        guard closes.count > period else {
            return Array(repeating: nil, count: closes.count)
        }

        var values = Array<Double?>(repeating: nil, count: closes.count)
        var averageGain = 0.0
        var averageLoss = 0.0

        for index in 1...period {
            let change = closes[index] - closes[index - 1]
            averageGain += max(change, 0)
            averageLoss += max(-change, 0)
        }

        averageGain /= Double(period)
        averageLoss /= Double(period)
        values[period] = rsi(averageGain: averageGain, averageLoss: averageLoss)

        guard closes.count > period + 1 else {
            return values
        }

        for index in (period + 1)..<closes.count {
            let change = closes[index] - closes[index - 1]
            let gain = max(change, 0)
            let loss = max(-change, 0)

            averageGain = ((averageGain * Double(period - 1)) + gain) / Double(period)
            averageLoss = ((averageLoss * Double(period - 1)) + loss) / Double(period)
            values[index] = rsi(averageGain: averageGain, averageLoss: averageLoss)
        }

        return values
    }

    private func rsi(averageGain: Double, averageLoss: Double) -> Double {
        if averageLoss == 0 {
            return averageGain == 0 ? 50 : 100
        }

        let relativeStrength = averageGain / averageLoss
        return 100 - (100 / (1 + relativeStrength))
    }
}

enum StockPriceError: LocalizedError {
    case invalidURL
    case badResponse
    case noData

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "De Yahoo Finance URL kon niet worden gemaakt."
        case .badResponse:
            return "Yahoo Finance gaf geen geldige response terug."
        case .noData:
            return "Er zijn geen slotkoersen gevonden voor dit symbool."
        }
    }
}

struct YahooChartResponse: Decodable {
    let chart: ChartData

    struct ChartData: Decodable {
        let result: [ResultData]
    }

    struct ResultData: Decodable {
        let timestamp: [Int]?
        let indicators: Indicators
    }

    struct Indicators: Decodable {
        let quote: [Quote]
    }

    struct Quote: Decodable {
        let close: [Double?]
        let high: [Double?]
        let low: [Double?]
        let volume: [Int?]
    }
}

struct ContentView: View {
    @State private var viewModel = StockPriceViewModel()
    @State private var symbolInput = "ADYEN.AS"
    @State private var historicalDayCount = 30
    @AppStorage("favoriteStockSymbols") private var storedFavoriteSymbols = "ADYEN.AS,ASML.AS,BESI.AS,AAPL,TSLA"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    symbolSelector
                    header

                    Group {
                        if viewModel.isLoading {
                            ProgressView("Koersen laden...")
                                .frame(maxWidth: .infinity, minHeight: 320)
                        } else if let errorMessage = viewModel.errorMessage {
                            ContentUnavailableView(
                                "Geen koersen beschikbaar",
                                systemImage: "chart.line.downtrend.xyaxis",
                                description: Text(errorMessage)
                            )
                            .frame(minHeight: 320)
                        } else {
                            charts
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Aandelenkoers")
            .toolbar {
                Button {
                    loadSelectedSymbol()
                } label: {
                    Label("Ververs", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading || trimmedSymbolInput.isEmpty)
            }
            .task {
                if viewModel.prices.isEmpty {
                    await viewModel.loadPrices(symbol: symbolInput, dayCount: historicalDayCount)
                }
            }
            .onChange(of: historicalDayCount) { _, _ in
                loadSelectedSymbol()
            }
        }
    }

    private var trimmedSymbolInput: String {
        symbolInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedSymbolInput: String {
        trimmedSymbolInput.uppercased()
    }

    private var favoriteSymbols: [String] {
        storedFavoriteSymbols
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }
    }

    private var symbolSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("Ticker", text: $symbolInput)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.search)
                    .onSubmit {
                        loadSelectedSymbol()
                    }

                Button {
                    loadSelectedSymbol()
                } label: {
                    Label("Laad", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isLoading || trimmedSymbolInput.isEmpty)

                Button {
                    addCurrentSymbolToFavorites()
                } label: {
                    Label("Bewaar", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .disabled(trimmedSymbolInput.isEmpty || favoriteSymbols.contains(normalizedSymbolInput))
            }

            Stepper(value: $historicalDayCount, in: 15...90, step: 5) {
                Text("historische dagen: \(historicalDayCount)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .disabled(viewModel.isLoading)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(favoriteSymbols, id: \.self) { symbol in
                        HStack(spacing: 4) {
                            Button(symbol) {
                                symbolInput = symbol
                                loadSelectedSymbol()
                            }
                            .buttonStyle(.bordered)
                            .tint(symbol == viewModel.symbol ? .blue : .secondary)

                            Button {
                                removeFavoriteSymbol(symbol)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .disabled(favoriteSymbols.count == 1)
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text(viewModel.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(viewModel.latestPrice?.close.formatted(.currency(code: "EUR")) ?? "--")
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
            }

            Spacer()

            if let priceChange = viewModel.priceChange {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("koersverschil")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(priceChange, format: .currency(code: "EUR"))
                        .font(.headline)
                        .foregroundStyle(priceChange >= 0 ? .green : .red)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background((priceChange >= 0 ? Color.green : Color.red).opacity(0.12), in: Capsule())
            }
        }
    }

    private func loadSelectedSymbol() {
        symbolInput = normalizedSymbolInput

        Task {
            await viewModel.loadPrices(symbol: symbolInput, dayCount: historicalDayCount)
        }
    }

    private func addCurrentSymbolToFavorites() {
        let symbol = normalizedSymbolInput

        guard !symbol.isEmpty, !favoriteSymbols.contains(symbol) else {
            return
        }

        saveFavoriteSymbols(favoriteSymbols + [symbol])
    }

    private func removeFavoriteSymbol(_ symbol: String) {
        let updatedSymbols = favoriteSymbols.filter { $0 != symbol }

        guard !updatedSymbols.isEmpty else {
            return
        }

        saveFavoriteSymbols(updatedSymbols)

        if symbol == symbolInput {
            symbolInput = updatedSymbols[0]
        }
    }

    private func saveFavoriteSymbols(_ symbols: [String]) {
        storedFavoriteSymbols = symbols.joined(separator: ",")
    }

    private var charts: some View {
        VStack(alignment: .leading, spacing: 18) {
            priceChart

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("RSI 14")
                        .font(.headline)

                    Spacer()

                    if let latestRSI = viewModel.latestPrice?.rsi {
                        Text(latestRSI.formatted(.number.precision(.fractionLength(1))))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                rsiChart
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Stochastic 14,3")
                        .font(.headline)

                    Spacer()

                    if let latestK = viewModel.latestPrice?.stochasticK,
                       let latestD = viewModel.latestPrice?.stochasticD {
                        Text("%K \(latestK.formatted(.number.precision(.fractionLength(1))))  %D \(latestD.formatted(.number.precision(.fractionLength(1))))")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                stochasticChart
            }
        }
    }

    private var priceChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Label("Koers", systemImage: "chart.line.uptrend.xyaxis")
                    .foregroundStyle(.blue)

                if let latestVolume = viewModel.latestPrice?.volume {
                    Label("Volume: \(latestVolume.formatted(.number.notation(.compactName)))", systemImage: "chart.bar.fill")
                        .foregroundStyle(.teal)
                }
            }
            .font(.caption)

            Chart {
                ForEach(viewModel.prices) { price in
                    if let volumeTop = scaledVolumeValue(price.volume), let volumeBaseline {
                        BarMark(
                            x: .value("Datum", price.date),
                            yStart: .value("Volume basis", volumeBaseline),
                            yEnd: .value("Volume", volumeTop)
                        )
                        .foregroundStyle(.teal.opacity(0.34))
                    }

                    AreaMark(
                        x: .value("Datum", price.date),
                        y: .value("Slotkoers", price.close)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.linearGradient(
                        colors: [.blue.opacity(0.18), .blue.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))

                    LineMark(
                        x: .value("Datum", price.date),
                        y: .value("Slotkoers", price.close)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.blue)
                }
            }
            .chartYAxisLabel("Prijs")
            .chartXScale(domain: visibleDateRange)
            .chartXAxis {
                AxisMarks(values: .stride(by: .weekOfYear)) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .frame(height: 300)
        }
    }

    private var dateRange: ClosedRange<Date>? {
        guard let startDate = viewModel.prices.first?.date,
              let endDate = viewModel.prices.last?.date else {
            return nil
        }

        return startDate...endDate
    }

    private var visibleDateRange: ClosedRange<Date> {
        if let dateRange {
            return dateRange
        }

        let now = Date()
        return now...now.addingTimeInterval(86_400)
    }

    private var priceRange: ClosedRange<Double>? {
        guard let minPrice = viewModel.prices.map(\.close).min(),
              let maxPrice = viewModel.prices.map(\.close).max() else {
            return nil
        }

        if minPrice == maxPrice {
            return (minPrice - 1)...(maxPrice + 1)
        }

        return minPrice...maxPrice
    }

    private var volumeBaseline: Double? {
        priceRange?.lowerBound
    }

    private var maximumVolume: Int? {
        viewModel.prices.map(\.volume).max()
    }

    private func scaledVolumeValue(_ volume: Int) -> Double? {
        guard let priceRange, let maximumVolume, maximumVolume > 0 else {
            return nil
        }

        let priceSpan = priceRange.upperBound - priceRange.lowerBound
        let volumeBandHeight = priceSpan * 0.28
        let normalizedVolume = Double(volume) / Double(maximumVolume)
        return priceRange.lowerBound + (normalizedVolume * volumeBandHeight)
    }

    private var rsiChart: some View {
        Chart {
            RuleMark(y: .value("Overbought", 70))
                .foregroundStyle(.red.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

            RuleMark(y: .value("Oversold", 30))
                .foregroundStyle(.green.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

            ForEach(viewModel.prices) { price in
                if let rsi = price.rsi {
                    LineMark(
                        x: .value("Datum", price.date),
                        y: .value("RSI", rsi)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.purple)
                }
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: visibleDateRange)
        .chartYAxis {
            AxisMarks(position: .leading, values: [30, 50, 70])
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .weekOfYear)) { _ in
                AxisTick()
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .frame(height: 150)
    }

    private var stochasticChart: some View {
        Chart {
            RuleMark(y: .value("Overbought", 80))
                .foregroundStyle(.red.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

            RuleMark(y: .value("Oversold", 20))
                .foregroundStyle(.green.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

            ForEach(viewModel.prices) { price in
                if let stochasticK = price.stochasticK {
                    LineMark(
                        x: .value("Datum", price.date),
                        y: .value("%K", stochasticK),
                        series: .value("Lijn", "%K")
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.orange)
                }

                if let stochasticD = price.stochasticD {
                    LineMark(
                        x: .value("Datum", price.date),
                        y: .value("%D", stochasticD),
                        series: .value("Lijn", "%D")
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.pink)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                }
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: visibleDateRange)
        .chartYAxis {
            AxisMarks(position: .leading, values: [20, 50, 80])
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .weekOfYear)) { _ in
                AxisTick()
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .frame(height: 150)
    }

}

#Preview {
    ContentView()
}
