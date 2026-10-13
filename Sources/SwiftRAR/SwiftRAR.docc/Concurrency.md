# Concurrency

What can run in parallel, what must stay in one task, and how to keep the
UI responsive.

## The contract

- ``convertToCBZ(from:to:limits:progress:)`` is a synchronous function
  without shared state. Calls on different files may run at the same time;
  their memory adds up.
- ``RARReader``, `RARArchive`, `FileSource`, `DataSource`, `CBZWriter` and
  `FileOutput` are **not** thread-safe and not `Sendable`. A file source
  seeks one file handle; a reader keeps a decoder session and a cursor. Use
  each instance from one task. To read in parallel, open a second reader.
- `Limits`, ``RARReader/Entry``, ``ConversionResult``, `RARError` and
  `CBZWriterError` are `Sendable` values.
- Cancellation is cooperative. The work checks `Task.isCancelled` at every
  header, output chunk and input read, and throws ``RARError/cancelled``.
- The `progress` closure and the sink of ``RARReader/extract(_:into:)``
  are called synchronously, on the thread doing the work.

## Keeping the UI responsive

The work is synchronous, so the thread that calls it is busy until it
returns. A `Task {}` started from a SwiftUI view inherits the main actor,
and from Swift 6.2 a `nonisolated async` function runs on its caller's
actor as well. Neither moves the work off the main thread. Use a detached
task, and forward cancellation to it, because a detached task is not
cancelled together with its parent:

```swift
@MainActor
final class ConversionModel: ObservableObject {
    @Published var fraction = 0.0
    private var task: Task<Void, Never>?

    func convert(_ source: URL, to destination: URL) {
        task = Task {
            let worker = Task.detached(priority: .userInitiated) { [weak self] in
                try convertToCBZ(from: source, to: destination, limits: .default) { fraction in
                    Task { @MainActor in self?.fraction = fraction }
                }
            }
            let outcome = await withTaskCancellationHandler {
                await worker.result
            } onCancel: {
                worker.cancel()
            }
            // Update state from `outcome` here, on the main actor.
            _ = outcome
        }
    }

    func cancel() { task?.cancel() }
}
```

Progress updates hop to the main actor one by one and may arrive after
the result, so ignore any that come in once the conversion has finished.
`Examples/SwiftUIConvert` in the repository is a complete, compiling app
that does this, including throttled progress and security-scoped file
access.
