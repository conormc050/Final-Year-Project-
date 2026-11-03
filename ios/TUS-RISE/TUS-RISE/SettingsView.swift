//
//  SettingsView.swift
//  TUS-RISE
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("tusrise.theme") private var theme = "system"
    @AppStorage("tusrise.viewMode") private var viewMode = "simple"
    @AppStorage("tusrise.athlete") private var athlete = "Athlete"

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
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 30)
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
