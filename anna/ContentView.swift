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
    let adx: Double?
}

@MainActor
@Observable
final class StockPriceViewModel {
    private(set) var prices: [StockPrice] = []
    private(set) var symbol = "ADYEN.AS"
    private(set) var historicalDayCount = 30
    private(set) var isLoading = false
    var errorMessage: String?

    private let service = MarketstackService()

    var latestPrice: StockPrice? {
        prices.last
    }

    var priceChange: Double? {
        guard let first = prices.first?.close, let last = prices.last?.close else {
            return nil
        }

        return last - first
    }

    func loadPrices(symbol requestedSymbol: String? = nil, dayCount requestedDayCount: Int? = nil, apiKey: String) async {
        let normalizedSymbol = (requestedSymbol ?? symbol)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let normalizedDayCount = min(max(requestedDayCount ?? historicalDayCount, 15), 90)

        guard !normalizedSymbol.isEmpty else {
            prices = []
            errorMessage = "Vul een ticker-symbool in, bijvoorbeeld ADYEN.AS of AAPL."
            return
        }

        let sanitizedAPIKey = MarketstackService.sanitizedAPIKey(from: apiKey)
        guard !sanitizedAPIKey.isEmpty else {
            prices = []
            errorMessage = "Vul eerst je Marketstack API key in."
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            prices = try await service.fetchLastClosingPrices(symbol: normalizedSymbol, count: normalizedDayCount, apiKey: sanitizedAPIKey)
            symbol = normalizedSymbol
            historicalDayCount = normalizedDayCount
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

struct MarketstackService {
    func fetchLastClosingPrices(symbol: String, count: Int, apiKey: String) async throws -> [StockPrice] {
        let priceResponse = try await fetchPrices(symbol: symbol, count: count, apiKey: apiKey)
        let entries = priceResponse.data
            .sorted { $0.date < $1.date }
            .map { price -> (date: Date, close: Double, high: Double, low: Double, volume: Int) in
                (
                    date: price.date,
                    close: price.adjustedClose ?? price.close,
                    high: price.adjustedHigh ?? price.high,
                    low: price.adjustedLow ?? price.low,
                    volume: Int(price.adjustedVolume ?? price.volume)
                )
            }

        guard !entries.isEmpty else {
            throw StockPriceError.noData
        }

        let rsiValues = calculateRSI(for: entries.map(\.close), period: 14)
        let stochasticValues = calculateStochasticOscillator(entries: entries, period: 14, signalPeriod: 3)
        let adxValues = calculateADX(entries: entries, period: 14)
        let prices = entries.enumerated().map { index, entry in
            StockPrice(
                date: entry.date,
                close: entry.close,
                volume: entry.volume,
                rsi: rsiValues[index],
                stochasticK: stochasticValues[index].k,
                stochasticD: stochasticValues[index].d,
                adx: adxValues[index]
            )
        }

        return Array(prices.suffix(count))
    }

    private func fetchPrices(symbol: String, count: Int, apiKey: String) async throws -> MarketstackEODResponse {
        let dates = dateRange(for: count)
        var components = URLComponents(string: "https://api.marketstack.com/v2/eod")
        components?.queryItems = [
            URLQueryItem(name: "access_key", value: apiKey),
            URLQueryItem(name: "symbols", value: marketstackSymbol(for: symbol)),
            URLQueryItem(name: "date_from", value: dates.start),
            URLQueryItem(name: "date_to", value: dates.end),
            URLQueryItem(name: "sort", value: "ASC"),
            URLQueryItem(name: "limit", value: String(max(count * 3, 100)))
        ]

        guard let url = components?.url else {
            throw StockPriceError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw StockPriceError.badResponse(statusCode: nil, detail: nil)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw StockPriceError.badResponse(
                statusCode: httpResponse.statusCode,
                detail: MarketstackErrorResponse.detail(from: data)
            )
        }

        if let errorDetail = MarketstackErrorResponse.detail(from: data) {
            throw StockPriceError.badResponse(statusCode: httpResponse.statusCode, detail: errorDetail)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(MarketstackEODPrice.decodeDate)

        do {
            return try decoder.decode(MarketstackEODResponse.self, from: data)
        } catch {
            throw StockPriceError.decodingFailed(error.localizedDescription)
        }
    }

    private func marketstackSymbol(for symbol: String) -> String {
        symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    static func sanitizedAPIKey(from apiKey: String) -> String {
        let trimmedAPIKey = apiKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

        if let url = URL(string: trimmedAPIKey),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let accessKeyQueryValue = components.queryItems?.first(where: { $0.name == "access_key" })?.value {
            return sanitizedAPIKey(from: accessKeyQueryValue)
        }

        for prefix in ["MARKETSTACK_API_KEY=", "access_key="] {
            if trimmedAPIKey.hasPrefix(prefix) {
                return sanitizedAPIKey(from: String(trimmedAPIKey.dropFirst(prefix.count)))
            }
        }

        return trimmedAPIKey
    }

    private func dateRange(for count: Int) -> (start: String, end: String) {
        let endDate = Date()
        let lookbackDays = max(count * 3, 90)
        let startDate = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: endDate) ?? endDate
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        return (formatter.string(from: startDate), formatter.string(from: endDate))
    }

    private func calculateADX(
        entries: [(date: Date, close: Double, high: Double, low: Double, volume: Int)],
        period: Int
    ) -> [Double?] {
        guard entries.count > period * 2 else {
            return Array(repeating: nil, count: entries.count)
        }

        var trueRanges = Array(repeating: 0.0, count: entries.count)
        var positiveDM = Array(repeating: 0.0, count: entries.count)
        var negativeDM = Array(repeating: 0.0, count: entries.count)

        for index in 1..<entries.count {
            let current = entries[index]
            let previous = entries[index - 1]
            let highLow = current.high - current.low
            let highPreviousClose = abs(current.high - previous.close)
            let lowPreviousClose = abs(current.low - previous.close)
            trueRanges[index] = max(highLow, highPreviousClose, lowPreviousClose)

            let upwardMove = current.high - previous.high
            let downwardMove = previous.low - current.low
            positiveDM[index] = upwardMove > downwardMove && upwardMove > 0 ? upwardMove : 0
            negativeDM[index] = downwardMove > upwardMove && downwardMove > 0 ? downwardMove : 0
        }

        var smoothedTR = trueRanges[1...period].reduce(0, +)
        var smoothedPositiveDM = positiveDM[1...period].reduce(0, +)
        var smoothedNegativeDM = negativeDM[1...period].reduce(0, +)
        var dxValues = Array<Double?>(repeating: nil, count: entries.count)

        dxValues[period] = dx(
            smoothedTR: smoothedTR,
            smoothedPositiveDM: smoothedPositiveDM,
            smoothedNegativeDM: smoothedNegativeDM
        )

        guard entries.count > period + 1 else {
            return Array(repeating: nil, count: entries.count)
        }

        for index in (period + 1)..<entries.count {
            smoothedTR = smoothedTR - (smoothedTR / Double(period)) + trueRanges[index]
            smoothedPositiveDM = smoothedPositiveDM - (smoothedPositiveDM / Double(period)) + positiveDM[index]
            smoothedNegativeDM = smoothedNegativeDM - (smoothedNegativeDM / Double(period)) + negativeDM[index]
            dxValues[index] = dx(
                smoothedTR: smoothedTR,
                smoothedPositiveDM: smoothedPositiveDM,
                smoothedNegativeDM: smoothedNegativeDM
            )
        }

        var adxValues = Array<Double?>(repeating: nil, count: entries.count)
        let firstADXIndex = period * 2
        let initialDXValues = dxValues[(period + 1)...firstADXIndex].compactMap { $0 }

        guard initialDXValues.count == period else {
            return adxValues
        }

        var previousADX = initialDXValues.reduce(0, +) / Double(period)
        adxValues[firstADXIndex] = previousADX

        guard entries.count > firstADXIndex + 1 else {
            return adxValues
        }

        for index in (firstADXIndex + 1)..<entries.count {
            guard let dx = dxValues[index] else {
                continue
            }

            previousADX = ((previousADX * Double(period - 1)) + dx) / Double(period)
            adxValues[index] = previousADX
        }

        return adxValues
    }

    private func dx(smoothedTR: Double, smoothedPositiveDM: Double, smoothedNegativeDM: Double) -> Double? {
        guard smoothedTR > 0 else {
            return nil
        }

        let positiveDI = 100 * (smoothedPositiveDM / smoothedTR)
        let negativeDI = 100 * (smoothedNegativeDM / smoothedTR)
        let sum = positiveDI + negativeDI

        guard sum > 0 else {
            return nil
        }

        return 100 * abs(positiveDI - negativeDI) / sum
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
    case badResponse(statusCode: Int?, detail: String?)
    case decodingFailed(String)
    case noData

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "De Marketstack URL kon niet worden gemaakt."
        case let .badResponse(statusCode, detail):
            let statusText = statusCode.map { "HTTP \($0)" } ?? "geen HTTP-status"
            let detailText = detail.map { " Marketstack meldt: \($0)" } ?? ""
            return "Marketstack gaf geen geldige response terug (\(statusText)).\(detailText) Controleer je API key en ticker-symbool."
        case let .decodingFailed(message):
            return "De Marketstack data kon niet worden gelezen. \(message)"
        case .noData:
            return "Er zijn geen Marketstack slotkoersen gevonden voor dit symbool."
        }
    }
}

struct MarketstackEODResponse: Decodable {
    let data: [MarketstackEODPrice]
}

struct MarketstackEODPrice: Decodable {
    let date: Date
    let high: Double
    let low: Double
    let close: Double
    let volume: Double
    let adjustedHigh: Double?
    let adjustedLow: Double?
    let adjustedClose: Double?
    let adjustedVolume: Double?

    enum CodingKeys: String, CodingKey {
        case date
        case high
        case low
        case close
        case volume
        case adjustedHigh = "adj_high"
        case adjustedLow = "adj_low"
        case adjustedClose = "adj_close"
        case adjustedVolume = "adj_volume"
    }

    nonisolated static func decodeDate(from decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let dateString = try container.decode(String.self)

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: dateString) {
            return date
        }

        let timezoneFormatter = DateFormatter()
        timezoneFormatter.calendar = Calendar(identifier: .gregorian)
        timezoneFormatter.locale = Locale(identifier: "en_US_POSIX")
        timezoneFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        if let date = timezoneFormatter.date(from: dateString) {
            return date
        }

        let dateOnlyFormatter = DateFormatter()
        dateOnlyFormatter.calendar = Calendar(identifier: .gregorian)
        dateOnlyFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateOnlyFormatter.dateFormat = "yyyy-MM-dd"
        if let date = dateOnlyFormatter.date(from: dateString) {
            return date
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Ongeldig Marketstack datumformaat: \(dateString)"
        )
    }
}

struct MarketstackErrorResponse: Decodable {
    let error: APIError?

    struct APIError: Decodable {
        let code: String?
        let message: String?
    }

    static func detail(from data: Data) -> String? {
        guard let response = try? JSONDecoder().decode(MarketstackErrorResponse.self, from: data),
              let error = response.error else {
            return nil
        }

        let detail = [error.code, error.message]
            .compactMap { $0 }
            .joined(separator: ": ")
        return detail.isEmpty ? nil : detail
    }
}

struct ContentView: View {
    @State private var viewModel = StockPriceViewModel()
    @State private var symbolInput = "ADYEN.AS"
    @State private var historicalDayCount = 30
    @State private var showingInfo = false
    @AppStorage("marketstackAPIKey") private var marketstackAPIKey = ""
    @AppStorage("favoriteStockSymbols") private var storedFavoriteSymbols = "ADYEN.AS,ASML.AS,BESI.AS,AAPL,TSLA"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    apiKeyInput
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
            .navigationTitle("KoersKompas")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showingInfo = true
                    } label: {
                        Label("Info", systemImage: "info.circle")
                    }

                    Button {
                        loadSelectedSymbol()
                    } label: {
                        Label("Ververs", systemImage: "arrow.clockwise")
                    }
                    .disabled(viewModel.isLoading || trimmedSymbolInput.isEmpty || trimmedMarketstackAPIKey.isEmpty)
                }
            }
            .sheet(isPresented: $showingInfo) {
                InfoView()
            }
            .task {
                if viewModel.prices.isEmpty {
                    await viewModel.loadPrices(symbol: symbolInput, dayCount: historicalDayCount, apiKey: marketstackAPIKey)
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

    private var trimmedMarketstackAPIKey: String {
        MarketstackService.sanitizedAPIKey(from: marketstackAPIKey)
    }

    private var favoriteSymbols: [String] {
        storedFavoriteSymbols
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }
    }

    private var apiKeyInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Marketstack API key")
                .font(.headline)

            HStack(spacing: 10) {
                SecureField("API key", text: $marketstackAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)

                Button {
                    marketstackAPIKey = ""
                } label: {
                    Label("Wis", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .disabled(marketstackAPIKey.isEmpty || viewModel.isLoading)
            }

            if trimmedMarketstackAPIKey.isEmpty {
                Label("Vul je Marketstack API key in om koersen te laden.", systemImage: "key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var tradingSignal: (text: String, color: Color) {
        guard let latestPrice = viewModel.latestPrice,
              let rsi = latestPrice.rsi,
              let adx = latestPrice.adx,
              adx > 25 else {
            return ("n/a", .secondary)
        }

        if rsi > 70 {
            return ("bullish", .green)
        }

        if rsi < 30 {
            return ("bearish", .red)
        }

        return ("n/a", .secondary)
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
                    Label("Save", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .disabled(trimmedSymbolInput.isEmpty || favoriteSymbols.contains(normalizedSymbolInput))
            }

            Picker("Historische dagen", selection: $historicalDayCount) {
                Text("30 dagen").tag(30)
                Text("60 dagen").tag(60)
            }
            .pickerStyle(.segmented)
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
            await viewModel.loadPrices(symbol: symbolInput, dayCount: historicalDayCount, apiKey: marketstackAPIKey)
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

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("ADX 14")
                        .font(.headline)

                    Spacer()

                    if let latestADX = viewModel.latestPrice?.adx {
                        Text(latestADX.formatted(.number.precision(.fractionLength(1))))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                adxChart
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

                Spacer()

                HStack(spacing: 4) {
                    Text("signaal")
                        .foregroundStyle(.secondary)

                    Text(tradingSignal.text)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(tradingSignal.color)
                }
            }
            .font(.caption)

            Chart {
                ForEach(viewModel.prices) { price in
                    if let volumeTop = scaledVolumeValue(price.volume), let volumeBaseline {
                        BarMark(
                            x: .value("Datum", price.date),
                            yStart: .value("Prijs", volumeBaseline),
                            yEnd: .value("Prijs", volumeTop)
                        )
                        .foregroundStyle(.teal.opacity(0.34))
                    }

                    AreaMark(
                        x: .value("Datum", price.date),
                        y: .value("Prijs", price.close)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.linearGradient(
                        colors: [.blue.opacity(0.18), .blue.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))

                    LineMark(
                        x: .value("Datum", price.date),
                        y: .value("Prijs", price.close)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.blue)
                }
            }
            .chartYAxisLabel("Prijs")
            .chartXScale(domain: visibleDateRange)
            .chartXAxis {
                AxisMarks(values: .stride(by: .weekOfYear, count: dateAxisWeekStride)) { _ in
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

    private var dateAxisWeekStride: Int {
        historicalDayCount == 60 ? 2 : 1
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
            RuleMark(y: .value("RSI", 70))
                .foregroundStyle(.red.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

            RuleMark(y: .value("RSI", 30))
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
            AxisMarks(values: .stride(by: .weekOfYear, count: dateAxisWeekStride)) { _ in
                AxisTick()
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .frame(height: 150)
    }

    private var stochasticChart: some View {
        Chart {
            RuleMark(y: .value("Stochastic", 80))
                .foregroundStyle(.red.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

            RuleMark(y: .value("Stochastic", 20))
                .foregroundStyle(.green.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

            ForEach(viewModel.prices) { price in
                if let stochasticK = price.stochasticK {
                    LineMark(
                        x: .value("Datum", price.date),
                        y: .value("Stochastic", stochasticK),
                        series: .value("Lijn", "%K")
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.orange)
                }

                if let stochasticD = price.stochasticD {
                    LineMark(
                        x: .value("Datum", price.date),
                        y: .value("Stochastic", stochasticD),
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
            AxisMarks(values: .stride(by: .weekOfYear, count: dateAxisWeekStride)) { _ in
                AxisTick()
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .frame(height: 150)
    }

    private var adxChart: some View {
        Chart {
            RuleMark(y: .value("ADX", 25))
                .foregroundStyle(.secondary.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

            ForEach(viewModel.prices) { price in
                if let adx = price.adx {
                    LineMark(
                        x: .value("Datum", price.date),
                        y: .value("ADX", adx)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.indigo)
                }
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: visibleDateRange)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 25, 50, 75])
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .weekOfYear, count: dateAxisWeekStride)) { _ in
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
