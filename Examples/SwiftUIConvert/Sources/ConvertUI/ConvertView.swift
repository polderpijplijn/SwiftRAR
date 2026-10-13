// SPDX-License-Identifier: MIT

import SwiftUI
import UniformTypeIdentifiers

/// Pick a CBR, convert it to CBZ, show progress, allow cancelling.
public struct ConvertView: View {
    @StateObject private var model = ConversionModel()
    @State private var picking = false

    private static let types: [UTType] = ["cbr", "rar", "cbz", "zip"]
        .compactMap { UTType(filenameExtension: $0) }

    public init() {}

    public var body: some View {
        VStack(spacing: 16) {
            switch model.state {
            case .idle:
                Text("Choose a CBR to convert to CBZ.")
            case .converting(let fraction):
                ProgressView(value: fraction) {
                    Text("Converting…")
                } currentValueLabel: {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                }
            case .done(let url, let entries):
                Text("Saved \(entries) files to \(url.lastPathComponent).")
            case .stopped:
                Text("Stopped.")
            case .failed(let message):
                Text(message).foregroundStyle(.red)
            }

            HStack {
                Button("Choose File…") { picking = true }
                    .disabled(model.isConverting)
                Button("Cancel", role: .cancel) { model.cancel() }
                    .disabled(!model.isConverting)
            }
        }
        .padding()
        .frame(minWidth: 320)
        .fileImporter(isPresented: $picking, allowedContentTypes: Self.types) { result in
            if case .success(let url) = result { model.convert(url) }
        }
    }
}
