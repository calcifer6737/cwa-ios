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
            Picker(selection: $appearance) {
                ForEach(["Automatic", "Light", "Dark"], id: \.self) { Text($0).tag($0) }
            } label: { Label("Appearance", systemImage: "moon") }
            Picker(selection: $accent) {
                ForEach(AccentChoice.names, id: \.self) { name in
                    Label { Text(name) } icon: { Image(systemName: "circle.fill").foregroundStyle(AccentChoice.color(name)) }.tag(name)
                }
            } label: { Label("Accent Color", systemImage: "paintpalette") }
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
        .onAppear { icon = UIApplication.shared.alternateIconName ?? "Default" }
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
                            Image("Preview" + name).resizable().aspectRatio(1, contentMode: .fit)
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
