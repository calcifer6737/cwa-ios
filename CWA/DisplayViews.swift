import SwiftUI
import UIKit

enum AccentChoice {
    static let names = ["Default", "Mail", "Podcasts", "Fitness", "Music", "Watch", "Notes", "Books", "Prologue", "Barbie", "Plex"]
    static func color(_ name: String) -> Color {
        switch name {
        case "Mail": return .blue
        case "Podcasts": return .purple
        case "Fitness": return Color(red: 0.48, green: 0.78, blue: 0.02)
        case "Music": return .red
        case "Watch": return .orange
        case "Notes": return .yellow
        case "Books": return .primary
        case "Prologue": return Color(red: 0.72, green: 0.52, blue: 0.35)
        case "Barbie": return .pink
        case "Plex": return Color(red: 0.88, green: 0.64, blue: 0)
        default: return .teal
        }
    }
}

struct DisplaySection: View {
    @AppStorage("appearance") private var appearance = "Automatic"
    @AppStorage("accent") private var accent = "Default"
    @State private var icon = UIApplication.shared.alternateIconName ?? "Default"
    var body: some View {
        Section("Display") {
            Menu {
                Picker("Appearance", selection: $appearance) {
                    ForEach(["Automatic", "Light", "Dark"], id: \.self) { Text($0).tag($0) }
                }
            } label: { settingRow("Appearance", symbol: "moon", value: appearance) }
            Menu {
                ForEach(AccentChoice.names, id: \.self) { name in
                    Button { accent = name } label: {
                        Label { Text((accent == name ? "✓ " : "") + name) } icon: {
                            Image(uiImage: swatch(name)).renderingMode(.original)
                        }
                    }
                }
            } label: { settingRow("Accent Color", symbol: "paintpalette", value: accent) }
            NavigationLink {
                AppIconPicker()
            } label: {
                HStack {
                    Label("App Icon", systemImage: "app.dashed")
                    Spacer()
                    Text(icon).foregroundStyle(.secondary)
                }
            }
        }
        .tint(AccentChoice.color(accent))
        .onAppear { icon = UIApplication.shared.alternateIconName ?? "Default" }
    }
    private func settingRow(_ title: String, symbol: String, value: String) -> some View {
        HStack {
            Label(title, systemImage: symbol).foregroundStyle(.primary)
            Spacer()
            Text(value).foregroundStyle(AccentChoice.color(accent))
            Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(AccentChoice.color(accent))
        }.contentShape(Rectangle())
    }
    private func swatch(_ name: String) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 22, height: 22)).image { _ in
            UIColor(AccentChoice.color(name)).setFill()
            UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: 20, height: 20)).fill()
        }.withRenderingMode(.alwaysOriginal)
    }

}

struct AppIconPicker: View {
    static let names = ["Default", "Books", "Podcasts", "Music", "Barbie", "Monochrome", "Plex", "Telegram", "Warp", "ATP"]
    @State private var selected = UIApplication.shared.alternateIconName ?? "Default"
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 75), spacing: 18)], spacing: 26) {
                ForEach(Self.names, id: \.self) { name in
                    Button { Task { await choose(name) } } label: {
                        VStack(spacing: 10) {
                            Image("Preview" + name).renderingMode(.original).resizable().aspectRatio(1, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 19))
                                .padding(5)
                                .overlay(RoundedRectangle(cornerRadius: 24).stroke(selected == name ? Color.primary : .clear, lineWidth: 2))
                            Text(name).font(.caption.weight(.semibold)).foregroundStyle(.primary)
                        }
                    }.buttonStyle(.plain).disabled(busy)
                        .accessibilityAddTraits(selected == name ? .isSelected : [])
                }
            }.padding(24)
        }
        .navigationTitle("App Icon").navigationBarTitleDisplayMode(.inline)
        .alert("Unable to change icon", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
    @MainActor private func choose(_ name: String) async {
        guard !busy, name != selected else { return }
        guard UIApplication.shared.supportsAlternateIcons else { error = "This installation does not support alternate app icons."; return }
        busy = true
        defer { busy = false }
        do {
            try await UIApplication.shared.setAlternateIconName(name == "Default" ? nil : name)
            selected = UIApplication.shared.alternateIconName ?? "Default"
        } catch { self.error = error.localizedDescription }
    }
}
