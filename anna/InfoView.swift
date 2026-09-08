import SwiftUI

struct InfoView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("KoersKompas") {
                    Text("KoersKompas toont historische koersdata, volume en technische indicatoren voor gekozen tickers.")
                    Text("Koersdata wordt opgehaald via de KoersKompas proxy en geleverd door Marketstack.")
                    Text("De getoonde data is historische EOD-data en is niet realtime.")
                }

                Section("Signaal") {
                    Text("bullish: ADX is hoger dan 25 en RSI is hoger dan 70.")
                    Text("bearish: ADX is hoger dan 25 en RSI is lager dan 30.")
                    Text("neutral: er is geen bullish of bearish signaal volgens deze regels.")
                }

                Section("Indicatoren") {
                    Text("RSI 14 meet momentum op een schaal van 0 tot 100.")
                    Text("Stochastic 14,3 vergelijkt de slotkoers met de recente high-low range.")
                    Text("ADX 14 meet trendsterkte. De richting van de trend staat hier niet in, alleen hoe sterk de trend is.")
                }

                Section("Disclaimer") {
                    Text("Deze app is uitsluitend bedoeld voor informatieve technische analyse en vormt geen beleggingsadvies, koopadvies of verkoopadvies.")
                    Text("Koersdata en indicatoren kunnen vertraagd, onvolledig of onjuist zijn. Controleer belangrijke beslissingen altijd bij een onafhankelijke bron.")
                }
            }
            .navigationTitle("Info")
            .toolbar {
                Button("Sluit") {
                    dismiss()
                }
            }
        }
    }
}

#Preview {
    InfoView()
}
