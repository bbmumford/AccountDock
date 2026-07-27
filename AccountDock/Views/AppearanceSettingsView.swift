import SwiftUI

struct AppearanceSettingsView: View {
    @AppStorage("accentPalette") private var accentPalette = "signal"
    @AppStorage("interfaceDensity") private var interfaceDensity = "comfortable"
    @AppStorage("cardCornerRadius") private var storedCardCornerRadius = 7.0
    @AppStorage("disableCardShadows") private var disableCardShadows = false
    @AppStorage("menuPanelWidth") private var storedMenuPanelWidth = 440.0
    @AppStorage("showProviderLabels") private var showProviderLabels = true
    @AppStorage("preferMonochromeIcons") private var preferMonochromeIcons = false
    @State private var cardCornerRadius = 7.0
    @State private var menuPanelWidth = 440.0

    private let accentChoices: [AccentChoice] = [
        .init(id: "signal", name: "Dock Blue", color: Color(red: 0x5E / 255.0, green: 0x6A / 255.0, blue: 0xD2 / 255.0)),
        .init(id: "ember", name: "Ember", color: Color(red: 0xE8 / 255.0, green: 0x6D / 255.0, blue: 0x45 / 255.0)),
        .init(id: "ocean", name: "Ocean", color: Color(red: 0.12, green: 0.48, blue: 0.92)),
        .init(id: "violet", name: "Violet", color: Color(red: 0.49, green: 0.25, blue: 0.93)),
        .init(id: "forest", name: "Forest", color: Color(red: 0.12, green: 0.62, blue: 0.38)),
        .init(id: "rose", name: "Rose", color: Color(red: 0.88, green: 0.23, blue: 0.45)),
        .init(id: "graphite", name: "Graphite", color: Color(red: 0.35, green: 0.38, blue: 0.43))
    ]

    var body: some View {
        Form {
            Section("Colour") {
                Picker("Accent colour", selection: $accentPalette) {
                    ForEach(accentChoices) { choice in
                        HStack {
                            Circle()
                                .fill(choice.color)
                                .frame(width: 12, height: 12)
                            Text(choice.name)
                        }
                        .tag(choice.id)
                    }
                }
                .pickerStyle(.menu)

                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.brand)
                        .frame(width: 14, height: 14)
                    Text("Changes apply immediately across AccountDock.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Layout") {
                Picker("Density", selection: $interfaceDensity) {
                    Text("Compact").tag("compact")
                    Text("Comfortable").tag("comfortable")
                    Text("Spacious").tag("spacious")
                }
                .pickerStyle(.segmented)

                LabeledContent("Card corners") {
                    HStack {
                        Slider(
                            value: $cardCornerRadius,
                            in: 0...24,
                            step: 1,
                            onEditingChanged: { editing in
                                if !editing { storedCardCornerRadius = cardCornerRadius }
                            }
                        )
                        .frame(width: 180)
                        Text("\(Int(cardCornerRadius)) pt").monospacedDigit()
                    }
                }

                LabeledContent("Menu width") {
                    HStack {
                        Slider(
                            value: $menuPanelWidth,
                            in: 340...620,
                            step: 10,
                            onEditingChanged: { editing in
                                if !editing { storedMenuPanelWidth = menuPanelWidth }
                            }
                        )
                        .frame(width: 180)
                        Text("\(Int(menuPanelWidth)) pt").monospacedDigit()
                    }
                }
            }

            Section("Details") {
                Toggle("Card shadows", isOn: Binding(
                    get: { !disableCardShadows },
                    set: { disableCardShadows = !$0 }
                ))
                Toggle("Show provider labels", isOn: $showProviderLabels)
                Toggle("Prefer monochrome icons", isOn: $preferMonochromeIcons)
            }

            Section {
                Text("Changes save automatically. Reopen the menu to refresh every surface.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            cardCornerRadius = storedCardCornerRadius
            menuPanelWidth = storedMenuPanelWidth
        }
    }
}

private struct AccentChoice: Identifiable {
    let id: String
    let name: String
    let color: Color
}
