//
//  SettingsView.swift
//  TUS-RISE
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: SessionStore
    @AppStorage("tusrise.theme") private var theme = "system"
    @AppStorage("tusrise.viewMode") private var viewMode = "simple"
    @AppStorage("tusrise.athlete") private var athlete = "Athlete"
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.backgroundGradient.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Settings").font(.system(size: 30, weight: .heavy))

                        GlassCard(label: "Profile") {
                            HStack {
                                Text("Name").foregroundStyle(.secondary)
                                Spacer()
                                TextField("Athlete", text: $athlete)
                                    .multilineTextAlignment(.trailing)
                                    .fontWeight(.semibold)
                            }
                            .font(.system(size: 14.5))
                        }

                        GlassCard(label: "Appearance") {
                            Picker("Theme", selection: $theme) {
                                Text("☀️ Light").tag("light")
                                Text("🌙 Dark").tag("dark")
                                Text("⚙️ Auto").tag("system")
                            }
                            .pickerStyle(.segmented)
                        }

                        GlassCard(label: "Analysis") {
                            VStack(spacing: 0) {
                                Toggle(isOn: Binding(
                                    get: { viewMode == "detailed" },
                                    set: { viewMode = $0 ? "detailed" : "simple" }
                                )) {
                                    SettingLabel(icon: "chart.bar.doc.horizontal",
                                                 name: "Detailed view by default",
                                                 desc: "Open sessions in full-data mode")
                                }
                                .tint(Theme.accentStrong)

                                Divider().opacity(0.4).padding(.vertical, 6)

                                HStack {
                                    SettingLabel(icon: "scope",
                                                 name: "Custom flag thresholds",
                                                 desc: "Tune sensitivity per exercise")
                                    Spacer()
                                    SoonTag()
                                }
                            }
                        }

                        GlassCard(label: "Developer") {
                            NavigationLink {
                                LiDARTestView()
                            } label: {
                                HStack {
                                    SettingLabel(icon: "dot.radiowaves.left.and.right",
                                                 name: "LiDAR depth test",
                                                 desc: "Proof of concept: spine keypoint depth")
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }

                        GlassCard(label: "About") {
                            VStack(spacing: 0) {
                                KVRow(key: "Version", value: "0.5.0 (prototype)")
                                Divider().opacity(0.4)
                                KVRow(key: "Pipeline", value: "MediaPipe + SpinePose + some other stuff im sure")
                                Divider().opacity(0.4)
                                KVRow(key: "Project", value: "TUS Athlone Research")
                                Divider().opacity(0.4)
                                DisclaimerNote().padding(.vertical, 8)
                            }
                        }

                        GlassCard(label: "Data") {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    SettingLabel(icon: "internaldrive",
                                                 name: "Saved reviews",
                                                 desc: "Stored on this device only")
                                    Spacer()
                                    Text("\(store.sessions.count)")
                                        .font(.system(size: 15, weight: .heavy))
                                        .foregroundStyle(.secondary)
                                }
                                Button(role: .destructive) {
                                    showClearConfirm = true
                                } label: {
                                    Label("Clear cache", systemImage: "trash")
                                        .font(.system(size: 14.5, weight: .semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(Theme.bad.opacity(0.14),
                                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                        .foregroundStyle(Theme.bad)
                                }
                                .buttonStyle(.plain)
                                .disabled(store.sessions.isEmpty)
                                .opacity(store.sessions.isEmpty ? 0.5 : 1)
                            }
                        }

                        FundingCard()
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 30)
                }
            }
            .confirmationDialog("Clear all saved reviews?",
                                isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("Delete \(store.sessions.count) saved review\(store.sessions.count == 1 ? "" : "s")", role: .destructive) {
                    store.clearAll()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This permanently removes every saved session from this device. It can't be undone.")
            }
        }
    }
}

/// ERDF communication & visibility compliance: the funding statement plus the
/// official (unaltered) logo block — Government of Ireland, Co-funded by the
/// European Union, Southern Regional Assembly, HEA. Required on all TUS RISE
/// funded outputs. Wording and the logo block must not be changed; the block
/// sits on a white panel so its colour marks stay legible in dark mode.
struct FundingCard: View {
    private let statementEN = "TUS RISE is co-funded by the Government of Ireland and the European Union through the ERDF Southern, Eastern & Midland Regional Programme 2021-27."
    private let statementGA = "Tá TUS RISE arna chomhchistiú ag Rialtas na hÉireann agus ag an Aontas Eorpach trí Chlár Réigiúnach an Deiscirt, an Oirthir agus Lár na Tíre 2021-27 de chuid CFRE."

    var body: some View {
        GlassCard(label: "Funding & acknowledgement") {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 12) {
                    Image("TUSLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 30)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.white,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityLabel("Technological University of the Shannon")
                    Text("A research project at the Technological University of the Shannon (TUS).")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider().opacity(0.4)

                Image("ERDFLogoBlock")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 190)
                    .frame(maxWidth: .infinity)          // centre in the card
                    .padding(16)
                    .background(Color.white,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityLabel("Co-funded by the Government of Ireland and the European Union through the ERDF, with the Southern Regional Assembly and the Higher Education Authority")

                Text(statementEN)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(statementGA)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Link(destination: URL(string: "https://tus.ie/rdi/tu-rise/")!) {
                        Label("tus.ie/rdi/tu-rise", systemImage: "link")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .tint(Theme.accentStrong)
                    Spacer()
                    Text("#EUinmyRegion")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

struct SettingLabel: View {
    let icon: String, name: String, desc: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .frame(width: 36, height: 36)
                .background(Theme.accent.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .foregroundStyle(Theme.accentStrong)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 14.5, weight: .semibold))
                Text(desc).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

struct SoonTag: View {
    var text = "Soon"
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold)).kerning(0.6)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.tertiary)
    }
}

struct SoonRow: View {
    let icon: String, name: String, desc: String
    var tag = "Soon"
    var body: some View {
        HStack {
            SettingLabel(icon: icon, name: name, desc: desc)
            Spacer()
            SoonTag(text: tag)
        }
        .padding(.vertical, 8)
    }
}

struct KVRow: View {
    let key: String, value: String
    var body: some View {
        HStack {
            Text(key).font(.system(size: 14)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 14, weight: .bold))
        }
        .padding(.vertical, 10)
    }
}
