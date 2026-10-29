import SwiftUI
import PhotosUI
import DesignSystem
import GlassesKit

/// Reusable image input: shows the selected image, or capture (glasses) / photo-pick controls.
struct ImageSourceView: View {
    @Binding var image: UIImage?
    @EnvironmentObject private var glasses: GlassesService
    @State private var pickerItem: PhotosPickerItem?
    @State private var capturing = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Palette.surface)
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
            if let image {
                Image(uiImage: image)
                    .resizable().scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                    .overlay(alignment: .topTrailing) {
                        Button { self.image = nil } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white, Theme.Palette.ink)
                                .padding(Theme.Spacing.sm)
                        }
                    }
            } else {
                VStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 44, weight: .thin))
                        .foregroundStyle(Theme.Palette.textMuted)
                    HStack(spacing: Theme.Spacing.md) {
                        if glasses.isAvailable {
                            Button(capturing ? "Capturing…" : "Capture") {
                                Task { capturing = true; await capture(); capturing = false }
                            }
                            .buttonStyle(.bordered).tint(Theme.Palette.accent).disabled(capturing)
                        }
                        PhotosPicker("Choose photo", selection: $pickerItem, matching: .images)
                            .tint(Theme.Palette.accent)
                    }
                }
            }
        }
        .onChange(of: pickerItem) { _, item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self) {
                    image = UIImage(data: data)
                }
            }
        }
    }

    private func capture() async {
        guard glasses.isAvailable else { return }
        let keepCameraOn = glasses.isStreaming
        if !glasses.isStreaming { await glasses.startStreaming() }
        if let data = try? await glasses.capturePhoto() {
            image = UIImage(data: data)
        } else if let jpeg = glasses.currentFrameJPEG() {
            image = UIImage(data: jpeg)
        }
        if !keepCameraOn {
            await glasses.stopStreaming()
        }
    }
}
