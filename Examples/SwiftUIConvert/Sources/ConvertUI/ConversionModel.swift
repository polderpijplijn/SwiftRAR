// SPDX-License-Identifier: MIT

import Foundation
import SwiftRAR

/// Runs one conversion at a time, off the main actor, and publishes its
/// progress and outcome on the main actor.
@MainActor
public final class ConversionModel: ObservableObject {
    public enum State: Equatable {
        case idle
        case converting(fraction: Double)
        case done(URL, entries: Int)
        case stopped
        case failed(String)
    }

    @Published public private(set) var state: State = .idle
    private var task: Task<Void, Never>?

    public init() {}

    public var isConverting: Bool {
        if case .converting = state { return true }
        return false
    }

    public func convert(_ source: URL) {
        cancel()
        state = .converting(fraction: 0)
        let destination = URL.documentsDirectory
            .appendingPathComponent(source.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("cbz")

        // This task inherits the main actor; it only waits and updates state.
        task = Task {
            // `convertToCBZ` is synchronous. A plain `Task {}` started here
            // would run it on the main actor and freeze the UI, so the work
            // goes to a detached task.
            let worker = Task.detached(priority: .userInitiated) { [weak self] in
                let accessing = source.startAccessingSecurityScopedResource()
                defer { if accessing { source.stopAccessingSecurityScopedResource() } }

                var reported = -1
                return try convertToCBZ(from: source, to: destination, limits: .default) { fraction in
                    // Called on this worker thread, once per entry. Forward
                    // whole percentages only, so the main actor is not flooded.
                    let percent = Int(fraction * 100)
                    guard percent != reported else { return }
                    reported = percent
                    Task { @MainActor in self?.report(fraction) }
                }
            }
            // A detached task is not cancelled with its parent: forward it.
            let outcome = await withTaskCancellationHandler {
                await worker.result
            } onCancel: {
                worker.cancel()
            }
            finish(outcome, destination: destination)
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }

    private func report(_ fraction: Double) {
        // Progress hops may arrive late or out of order; never go backwards
        // and never overwrite a finished state.
        guard case .converting(let current) = state else { return }
        state = .converting(fraction: max(current, fraction))
    }

    private func finish(_ outcome: Result<ConversionResult, Error>, destination: URL) {
        switch outcome {
        case .success(let result):
            state = .done(destination, entries: result.entryCount)
        case .failure(let error as RARError) where error.category == .cancelled:
            state = .stopped
        case .failure(let error):
            state = .failed(Self.message(for: error))
        }
    }

    /// User-facing text by error category; see the error guide in the docs.
    static func message(for error: Error) -> String {
        let category = (error as? RARError)?.category ?? (error as? CBZWriterError)?.category
        switch category {
        case .corrupt: return "This file is damaged or not a comic archive."
        case .unsupported: return "This archive uses a feature that is not supported (for example a password)."
        case .limit: return "This archive is too large to convert."
        case .io: return "The file could not be read or written."
        case .cancelled: return "Stopped."
        case .usage, nil: return "Conversion failed: \(error)"
        }
    }
}
