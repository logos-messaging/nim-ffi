// Idiomatic Swift wrapper over the timer library's native C ABI.
//
// Each call is dispatched on the library's background FFI thread and its result
// arrives on a callback; we bridge that to a synchronous Swift API with a
// semaphore. A struct return (EchoResponse) is read out of the typed C-POD
// inside the callback — it is valid only for the callback's lifetime.
import CMyTimer
import Foundation

public enum TimerError: Error, CustomStringConvertible {
    case failed(String)
    public var description: String {
        switch self { case let .failed(m): return m }
    }
}

public struct EchoResult: Equatable {
    public let echoed: String
    public let timerName: String
}

public final class TimerNode {
    private let ctx: UnsafeMutableRawPointer

    /// Creates the timer context (TimerConfig by value).
    public init(name: String) throws {
        let box = Box()
        let ud = Unmanaged.passUnretained(box).toOpaque()
        let cName = strdup(name)
        defer { free(cName) }
        var cfg = TimerConfig()
        cfg.name = UnsafePointer(cName)
        guard let c = my_timer_create(cfg, ackCallback, ud) else {
            throw TimerError.failed("create returned null")
        }
        box.sem.wait()
        guard box.ret == 0 else { throw TimerError.failed(box.text) }
        ctx = c
    }

    /// String-returning call: the raw bytes are the version string.
    public func version() throws -> String {
        let box = Box()
        let ud = Unmanaged.passUnretained(box).toOpaque()
        guard my_timer_version(ctx, stringCallback, ud) == 0 else {
            throw TimerError.failed("version dispatch failed")
        }
        box.sem.wait()
        guard box.ret == 0 else { throw TimerError.failed(box.text) }
        return box.text
    }

    /// Struct param in, typed struct (EchoResponse) out.
    public func echo(_ message: String, delayMs: Int = 0) throws -> EchoResult {
        let box = EchoBox()
        let ud = Unmanaged.passUnretained(box).toOpaque()
        let cMsg = strdup(message)
        defer { free(cMsg) }
        var req = EchoRequest()
        req.message = UnsafePointer(cMsg)
        req.delayMs = Int64(delayMs)
        guard my_timer_echo(ctx, echoCallback, ud, req) == 0 else {
            throw TimerError.failed("echo dispatch failed")
        }
        box.sem.wait()
        guard box.ret == 0 else { throw TimerError.failed(box.text) }
        return EchoResult(echoed: box.echoed, timerName: box.timerName)
    }

    deinit { my_timer_destroy(ctx) }
}

// MARK: - callback plumbing
// The library calls back on its FFI thread; we keep the Box alive on the caller
// stack (passUnretained) because the caller blocks on the semaphore until the
// callback fires.

final class Box {
    var ret: Int32 = -1
    var text = ""
    let sem = DispatchSemaphore(value: 0)
}
final class EchoBox {
    var ret: Int32 = -1
    var text = ""
    var echoed = ""
    var timerName = ""
    let sem = DispatchSemaphore(value: 0)
}

private func rawText(_ msg: UnsafePointer<CChar>?, _ len: Int) -> String {
    guard let m = msg, len > 0 else { return "" }
    let bytes = UnsafeRawPointer(m).assumingMemoryBound(to: UInt8.self)
    return String(decoding: UnsafeBufferPointer(start: bytes, count: len), as: UTF8.self)
}

private func ackCallback(_ ret: Int32, _ msg: UnsafePointer<CChar>?,
                         _ len: Int, _ ud: UnsafeMutableRawPointer?) {
    let box = Unmanaged<Box>.fromOpaque(ud!).takeUnretainedValue()
    box.ret = ret
    if ret != 0 { box.text = rawText(msg, len) }
    box.sem.signal()
}

private func stringCallback(_ ret: Int32, _ msg: UnsafePointer<CChar>?,
                            _ len: Int, _ ud: UnsafeMutableRawPointer?) {
    let box = Unmanaged<Box>.fromOpaque(ud!).takeUnretainedValue()
    box.ret = ret
    box.text = rawText(msg, len)
    box.sem.signal()
}

private func echoCallback(_ ret: Int32, _ msg: UnsafePointer<CChar>?,
                          _ len: Int, _ ud: UnsafeMutableRawPointer?) {
    let box = Unmanaged<EchoBox>.fromOpaque(ud!).takeUnretainedValue()
    box.ret = ret
    if ret == 0, let m = msg {
        // Native ABI: msg is a const EchoResponse* (typed struct return).
        let resp = UnsafeRawPointer(m).assumingMemoryBound(to: EchoResponse.self)
        box.echoed = resp.pointee.echoed.map { String(cString: $0) } ?? ""
        box.timerName = resp.pointee.timerName.map { String(cString: $0) } ?? ""
    } else {
        box.text = rawText(msg, len)
    }
    box.sem.signal()
}
