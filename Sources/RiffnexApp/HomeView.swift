import DesignSystem
import SwiftUI

/// M0 home: brand and an honest status. Song import arrives in M1, so it is not shown as a
/// disabled teaser; the only action is checking that this iPhone supports everything RIFFNEX needs.
struct HomeView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        ZStack {
            RXBackground()

            VStack(alignment: .leading, spacing: RX.Space.l) {
                Text("RIFFNEX")
                    .font(.footnote.weight(.heavy).width(.expanded))
                    .tracking(3)
                    .foregroundStyle(RX.Palette.textSecondary)
                    .accessibilityAddTraits(.isHeader)

                Spacer()

                VStack(alignment: .leading, spacing: RX.Space.xxs) {
                    Text(tr("home.tagline.1"))
                        .foregroundStyle(RX.Palette.textPrimary)
                    Text(tr("home.tagline.2"))
                        .foregroundStyle(RX.brandGradient)
                }
                .font(.rxDisplay(.largeTitle))
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared || reduceMotion ? 0 : 16)
                .accessibilityElement(children: .combine)

                Text("Importe uma música que é sua, veja notas, riffs e acordes no braço da guitarra e aprenda tocando.")
                    .font(.body)
                    .foregroundStyle(RX.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: RX.Space.xs) {
                    RXStatusPill("Versão de fundação (M0)", kind: .neutral)
                    Text("A importação de músicas chega no próximo marco. Por enquanto, verifique se tudo o que o RIFFNEX usa funciona neste iPhone.")
                        .font(.footnote)
                        .foregroundStyle(RX.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                NavigationLink {
                    DiagnosticsView()
                } label: {
                    Label("Verificar este iPhone", systemImage: "checklist")
                }
                .buttonStyle(RXPrimaryButtonStyle())
            }
            .padding(.horizontal, RX.Space.screenMargin)
            .padding(.bottom, RX.Space.l)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            withAnimation(RX.Motion.adaptive(RX.Motion.spatial, reduceMotion: reduceMotion)) { appeared = true }
        }
    }
}
