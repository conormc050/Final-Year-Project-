//
//  AnalyzeView.swift
//  TUS-RISE
//
//  Pick a recorded set from the photo library and run the on-device
//  pose analysis (VideoPoseAnalyzer).
//

import SwiftUI
import PhotosUI

struct AnalyzeView: View {
    @EnvironmentObject private var store: SessionStore

    @State private var showVideoPicker = false
    @State private var pickedVideo: PhotosPickerItem?
    @State private var analysisProgress: Double?
    @State private var analyzed: LiftSession?
    @State private var analysisError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.backgroundGradient.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Analyze").font(.system(size: 30, weight: .heavy))
                            Text("Check your form on a recorded set")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }

                        Button { showVideoPicker = true } label: {
                            VStack(spacing: 10) {
                                if let p = analysisProgress {
                                    ProgressView(value: p)
                                        .tint(Theme.accent)
                                        .padding(.horizontal, 30)
                                    Text("Analysing… \(Int(p * 100))%")
                                        .font(.system(size: 16, weight: .heavy))
                                    Text("Tracking your joints frame by frame")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                } else {
                                    Image(systemName: "video.badge.waveform")
                                        .font(.system(size: 38, weight: .medium))
                                        .foregroundStyle(Theme.accent)
                                    Text("Analyze a video")
                                        .font(.system(size: 16, weight: .heavy))
                                    Text("Pick a squat video from your library.\nEverything runs on your phone.")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                            .background(
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .strokeBorder(Theme.accent.opacity(0.5),
                                                  style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                                    .background(Theme.accent.opacity(0.06),
                                                in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(analysisProgress != nil)

                        GlassCard(label: "How to record") {
                            VStack(spacing: 0) {
                                StepRow(num: "1", text: "Film from the **side**, with your whole body in frame. Prop the phone up so it's steady.")
                                Divider().opacity(0.4)
                                StepRow(num: "2", text: "**Stand still for about 3 seconds** before your first rep — that's how the app learns your neutral stance.")
                                Divider().opacity(0.4)
                                StepRow(num: "3", text: "Do your set, then pick the video here to see reps, depth, and joint angles.")
                            }
                        }

                        GlassCard(label: "Coming soon") {
                            VStack(spacing: 0) {
                                StepRow(num: "📱", text: "**Record in-app** — capture your set straight from the camera.")
                                Divider().opacity(0.4)
                                StepRow(num: "⚡", text: "**Live mode** — real-time feedback while you lift.")
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 30)
                }
            }
            .photosPicker(isPresented: $showVideoPicker,
                          selection: $pickedVideo,
                          matching: .videos)
            .onChange(of: pickedVideo) { _, item in
                guard let item else { return }
                pickedVideo = nil
                analyzeVideo(item)
            }
            .sheet(item: $analyzed) { SessionDetailView(session: $0) }
            .alert("Analysis failed", isPresented: .constant(analysisError != nil)) {
                Button("OK") { analysisError = nil }
            } message: {
                Text(analysisError ?? "")
            }
        }
    }

    private func analyzeVideo(_ item: PhotosPickerItem) {
        analysisProgress = 0
        Task {
            do {
                guard let picked = try await item.loadTransferable(type: PickedVideo.self) else {
                    throw CocoaError(.fileReadUnknown)
                }
                defer { try? FileManager.default.removeItem(at: picked.url) }

                let payload = try await VideoPoseAnalyzer.analyze(url: picked.url) { p in
                    Task { @MainActor in analysisProgress = p }
                }
                let session = LiftSession(payload: payload)
                analysisProgress = nil
                analyzed = session   // shown for review; saved only if the user taps Save
            } catch {
                analysisProgress = nil
                analysisError = error.localizedDescription
            }
        }
    }
}

private struct StepRow: View {
    let num: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(num)
                .font(.system(size: 13, weight: .heavy))
                .frame(width: 28, height: 28)
                .background(Theme.accent.opacity(0.14), in: Circle())
                .foregroundStyle(Theme.accentStrong)
            Text(text)
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
    }
}

/// A video handed over by the Photos picker, copied to a temp file we own.
/// (Photos exports to a transient location that's deleted when the closure
/// returns, so the copy has to happen here, not later.)
nonisolated struct PickedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedVideo(url: dest)
        }
    }
}
