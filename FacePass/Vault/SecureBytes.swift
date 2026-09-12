import Darwin
import Foundation

/// Bytes kept in RAM that is locked against swapping and wiped when released.
/// Holds the decrypted account password only for as long as it is needed.
final class SecureBytes {
    private let pointer: UnsafeMutableRawPointer
    private let capacity: Int
    let count: Int

    init(_ data: Data) {
        count = data.count
        capacity = max(data.count, 1)
        pointer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<UInt8>.alignment)
        mlock(pointer, capacity)
        data.withUnsafeBytes { source in
            if let base = source.baseAddress {
                pointer.copyMemory(from: base, byteCount: count)
            }
        }
    }

    func withUnsafeBytes<Result>(_ body: (UnsafeRawBufferPointer) throws -> Result) rethrows -> Result {
        try body(UnsafeRawBufferPointer(start: pointer, count: count))
    }

    deinit {
        memset_s(pointer, capacity, 0, capacity)
        munlock(pointer, capacity)
        pointer.deallocate()
    }
}
