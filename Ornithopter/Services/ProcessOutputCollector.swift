import Darwin
import Foundation

nonisolated final class ProcessOutputCollector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Ornithopter.process-output")
    private let outputHandler: (@Sendable (String) -> Void)?
    private var data = Data()
    private var source: DispatchSourceRead?
    private var readError: Error?

    init(outputHandler: (@Sendable (String) -> Void)? = nil) {
        self.outputHandler = outputHandler
    }

    func start(readingFrom fileHandle: FileHandle) throws {
        let fd = fileHandle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags != -1, fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain(fd) }
        source.setCancelHandler { try? fileHandle.close() }
        self.source = source
        source.resume()
    }

    func stop(readingFrom fileHandle: FileHandle) {
        queue.sync { source?.cancel(); source = nil }
    }

    func finish(readingFrom fileHandle: FileHandle) throws -> String {
        try queue.sync {
            if source != nil { drain(fileHandle.fileDescriptor) }
            source?.cancel()
            source = nil
            if let readError { throw readError }
            return String(decoding: data, as: UTF8.self)
        }
    }

    private func drain(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                let chunk = Data(buffer.prefix(count))
                data.append(chunk)
                outputHandler?(String(decoding: chunk, as: UTF8.self))
            } else if count < 0 && errno == EINTR {
                continue
            } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                return
            } else {
                if count < 0 { readError = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                source?.cancel()
                source = nil
                return
            }
        }
    }
}
