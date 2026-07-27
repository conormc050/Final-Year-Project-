//
//  TUS_RISEApp.swift
//  TUS-RISE — Biomechanical lift analyser
//
//  App entry: splash → root tab shell. Theme follows the
//  "tusrise.theme" AppStorage key (system / light / dark).
//  Targets iOS 17+ (iPhone 14 and newer).
//

import SwiftUI

@main
struct TUS_RISEApp: App {
    @AppStorage("tusrise.theme") private var theme: String = "system"
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .opacity(showSplash ? 0 : 1)

                if showSplash {
                    SplashView()
                        .transition(.scale(scale: 1.06).combined(with: .opacity))
                }
            }
            .preferredColorScheme(colorScheme)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) {
                    withAnimation(.easeInOut(duration: 0.55)) { showSplash = false }
                }
            }
        }
    }

    private var colorScheme: ColorScheme? {
        switch theme {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil   // follow system
        }
    }
}

// MARK: - Root tab shell

struct RootView: View {
    @StateObject private var store = SessionStore()

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }
            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            AnalyzeView()
                .tabItem { Label("Analyze", systemImage: "plus.circle.fill") }
            TrendsView()
                .tabItem { Label("Trends", systemImage: "chart.line.uptrend.xyaxis") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(Theme.accent)
        .environmentObject(store)
    }
}

// MARK: - Splash

struct SplashView: View {
    @State private var drawn = false

    var body: some View {
        ZStack {
            Theme.backgroundGradient.ignoresSafeArea()

            // floating accent orbs
            Circle().fill(Theme.accentDeep).frame(width: 320)
                .blur(radius: 70).opacity(0.45)
                .offset(x: 150, y: -330)
            Circle().fill(Theme.accent).frame(width: 260)
                .blur(radius: 70).opacity(0.4)
                .offset(x: -150, y: 340)

            VStack(spacing: 10) {
                PulseMark()
                    .trim(from: 0, to: drawn ? 1 : 0)
                    .stroke(Theme.accentGradient,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    .frame(width: 96, height: 64)
                    .animation(.easeOut(duration: 1.2).delay(0.35), value: drawn)

                HStack(spacing: 0) {
                    Text("TUS-").font(.system(size: 40, weight: .heavy))
                    Text("RISE").font(.system(size: 40, weight: .heavy))
                        .foregroundStyle(Theme.accentGradient)
                }
                Text("Biomechanical lift analysis")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .overlay(alignment: .bottom) {
            // Institutional acknowledgement — TUS is the host of this research
            // internship. White panel keeps the logo unaltered and legible over
            // the dark gradient.
            VStack(spacing: 8) {
                Text("A research project at")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Image("TUSLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 34)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel("Technological University of the Shannon")
            }
            .padding(.bottom, 54)
            .opacity(drawn ? 1 : 0)
            .animation(.easeIn(duration: 0.6).delay(0.8), value: drawn)
        }
        .onAppear { drawn = true }
    }
}

/// The barbell-pulse logo path.
struct PulseMark: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height, mid = h * 0.5
        p.move(to: CGPoint(x: 0, y: mid))
        p.addLine(to: CGPoint(x: w * 0.22, y: mid))
        p.addLine(to: CGPoint(x: w * 0.32, y: h * 0.18))
        p.addLine(to: CGPoint(x: w * 0.48, y: h * 0.85))
        p.addLine(to: CGPoint(x: w * 0.60, y: h * 0.30))
        p.addLine(to: CGPoint(x: w * 0.68, y: mid))
        p.addLine(to: CGPoint(x: w, y: mid))
        return p
    }
}
