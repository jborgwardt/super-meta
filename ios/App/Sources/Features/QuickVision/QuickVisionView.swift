import SwiftUI
import PhotosUI
import SwiftData
import DesignSystem
import AIProviders
import GlassesKit
import Inject

@MainActor
final class QuickVisionViewModel: ObservableObject {
    @Published var mode: QuickVisionMode = .standard
    @Published var customPrompt = ""
    @Published var targetLanguage = "English"
    @Published var image: UIImage?
    @Published var result = ""
    @Published var isAnalyzing = false
    @Published var isCapturing = false
    @Published var error: String?

    func analyze(using providers: ProviderManager, glasses: GlassesService, context: ModelContext) async {
        guard let provider = providers.visionProvider() else {
            error = "No API key set for \(providers.visionVendor.displayName). Add one in Settings."
            return
        }
        guard let image, let jpeg = image.jpegData(compressionQuality: 0.8) else {
            error = "No image to analyze."
            return
        }
        error = nil
        isAnalyzing = true
        defer { isAnalyzing = false }

        let prompt = mode.prompt(custom: customPrompt, targetLanguage: targetLanguage)
        let request = AIRequest(
            model: providers.currentModel(),
            prompt: prompt,
            images: [AIImage(jpegData: jpeg)]
        )
        do {
            let text = try await provider.generate(request)
            result = text
            let thumb = image.scaledForThumbnail().jpegData(compressionQuality: 0.5)
            context.insert(VisionRecord(kind: .quickVision, prompt: prompt, result: text, thumbnail: thumb))
        } catch {
            self.error = (error as? AIProviderError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Pulls a fresh photo from the glasses when connected.
    func captureFromGlasses(_ glasses: GlassesService) async {
        guard glasses.isAvailable else { return }
        // Fail fast with a clear message instead of an 8s timeout when the glasses
        // aren't actually connected.
        guard glasses.hasActiveDevice else {
            error = "Glasses aren't connected. Put them on (or take them out of the case), then try again — or use Choose photo."
            return
        }
        error = nil
        isCapturing = true
        defer { isCapturing = false }
        let keepCameraOn = glasses.isStreaming
        if !glasses.isStreaming { await glasses.startStreaming() }
        do {
            let data = try await glasses.capturePhoto()
            image = UIImage(data: data)
        } catch {
            // The still-capture can time out before the stream warms up; fall back
            // to the most recent streamed frame.
            if let jpeg = glasses.currentFrameJPEG() {
                image = UIImage(data: jpeg)
            } else {
                self.error = "Couldn't get a photo from the glasses. Make sure they're connected, or use Choose photo."
            }
        }
        if !keepCameraOn {
            await glasses.stopStreaming()
        }
    }
}

struct QuickVisionView: View {
    @EnvironmentObject private var providers: ProviderManager
    @EnvironmentObject private var glasses: GlassesService
    @Environment(\.modelContext) private var context
    @StateObject private var vm = QuickVisionViewModel()
    @State private var pickerItem: PhotosPickerItem?
    @ObserveInjection var inject

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                modeSelector
                imageArea
                if vm.mode == .custom {
                    TextField("Custom prompt", text: $vm.customPrompt)
                        .padding(Theme.Spacing.md)
                        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                        .foregroundStyle(Theme.Palette.textPrimary)
                }
                analyzeButton
                resultArea
            }
            .padding(Theme.Spacing.lg)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle("Quick Vision")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.light)
        .enableInjection()
        .onChange(of: pickerItem) { _, item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self) {
                    vm.image = UIImage(data: data)
                }
            }
        }
    }

    private var modeSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(QuickVisionMode.allCases) { mode in
                    Button { vm.mode = mode } label: {
                        Label(mode.title, systemImage: mode.icon)
                            .font(Theme.Font.readout(13))
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.sm)
                            .background(
                                Capsule().fill(vm.mode == mode ? Theme.Palette.accent : Theme.Palette.surface)
                            )
                            .foregroundStyle(vm.mode == mode ? Theme.Palette.canvas : Theme.Palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var imageArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Palette.surface)
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
            if let image = vm.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            } else {
                VStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 44, weight: .thin))
                        .foregroundStyle(Theme.Palette.textMuted)
                    HStack(spacing: Theme.Spacing.md) {
                        if glasses.isAvailable {
                            Button(vm.isCapturing ? "Capturing…" : "Capture") {
                                Task { await vm.captureFromGlasses(glasses) }
                            }
                            .buttonStyle(.bordered).tint(Theme.Palette.accent)
                            .disabled(vm.isCapturing)
                        }
                        PhotosPicker("Choose photo", selection: $pickerItem, matching: .images)
                            .tint(Theme.Palette.accent)
                    }
                    if glasses.isAvailable && !glasses.hasActiveDevice {
                        Text("Capture uses your glasses camera — connect them first, or choose a photo.")
                            .font(Theme.Font.readout(12))
                            .foregroundStyle(Theme.Palette.textMuted)
                            .multilineTextAlignment(.center)
                    }
                }
            }
        }
    }

    private var analyzeButton: some View {
        HUDButton(vm.isAnalyzing ? "Analyzing…" : "Analyze", systemImage: "sparkles") {
            Task { await vm.analyze(using: providers, glasses: glasses, context: context) }
        }
        .disabled(vm.image == nil || vm.isAnalyzing)
        .opacity(vm.image == nil ? 0.5 : 1)
    }

    @ViewBuilder private var resultArea: some View {
        if let error = vm.error {
            HUDPanel { Text(error).font(Theme.Font.body(14)).foregroundStyle(Theme.Palette.live) }
        } else if !vm.result.isEmpty {
            HUDPanel {
                Text(vm.result)
                    .font(Theme.Font.body(15))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

extension UIImage {
    func scaledForThumbnail(maxWidth: CGFloat = 200) -> UIImage {
        guard size.width > maxWidth else { return self }
        let scale = maxWidth / size.width
        let newSize = CGSize(width: maxWidth, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}
