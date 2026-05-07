import Foundation

enum DirectoryMonitorError: LocalizedError {
    case openFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let path):
            return "Could not open \(path) for monitoring."
        }
    }
}

final class DirectoryMonitor: @unchecked Sendable {
    private let url: URL
    private let fileManager: FileManager
    private let eventHandler: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.huntae.tinkerbar.directorymonitor")

    private var fileDescriptor: CInt = -1
    private var source: DispatchSourceFileSystemObject?
    private var knownEntryIDs: Set<String> = []

    init(url: URL, fileManager: FileManager = .default, eventHandler: @escaping @Sendable () -> Void) {
        self.url = url
        self.fileManager = fileManager
        self.eventHandler = eventHandler
    }

    func start() throws {
        guard source == nil else { return }

        fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            throw DirectoryMonitorError.openFailed(url.path)
        }

        knownEntryIDs = currentRegularFileIDs()

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            self?.handleDirectoryWrite()
        }
        source.setCancelHandler { [fileDescriptor] in
            close(fileDescriptor)
        }
        source.resume()

        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
        fileDescriptor = -1
    }

    private func handleDirectoryWrite() {
        let currentEntryIDs = currentRegularFileIDs()
        let newEntryIDs = currentEntryIDs.subtracting(knownEntryIDs)
        knownEntryIDs = currentEntryIDs

        guard !newEntryIDs.isEmpty else { return }
        eventHandler()
    }

    private func currentRegularFileIDs() -> Set<String> {
        let entryURLs = (try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return Set(entryURLs.compactMap { entryURL in
            guard
                let resourceValues = try? entryURL.resourceValues(forKeys: [.isRegularFileKey]),
                resourceValues.isRegularFile == true,
                let attributes = try? fileManager.attributesOfItem(atPath: entryURL.path),
                let systemNumber = attributes[.systemNumber],
                let fileNumber = attributes[.systemFileNumber]
            else {
                return nil
            }

            return "\(systemNumber):\(fileNumber)"
        })
    }
}
