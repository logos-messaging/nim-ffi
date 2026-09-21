// ============================================================
// Message dispatch
// ============================================================
// The library never calls into the host. Each context owns one dispatch thread that
// takes everything the library sends out through `<lib>_poll`: a reply goes to
// the call waiting for it, anything else to the listeners registered for it.
// Guarded so two nim-ffi headers can share a translation unit.
#ifndef NIM_FFI_DISPATCHER_HPP_INCLUDED
#define NIM_FFI_DISPATCHER_HPP_INCLUDED

class NimFfiDispatcher : public std::enable_shared_from_this<NimFfiDispatcher> {
public:
    using Bytes = std::vector<std::uint8_t>;
    using PollFn = int (*)(void* ctx, std::int32_t timeout_ms, const NimFfiMsg** msg);
    using LastErrorFn = const char* (*)();
    // Decodes one NIMFFI_MSG_EVENT and delivers it; generated per library.
    using EventFn = void (*)(NimFfiDispatcher& dispatcher, const NimFfiMsg& msg);
    // What a reply (or the lack of one) resolves to. Runs on the dispatch thread, so
    // it holds no user code: it decodes and hands the value over.
    using Completion = std::function<void(Result<Bytes>)>;

    using StaleWarnFn = std::function<void(std::uint64_t reqId, std::uint64_t elapsedMs)>;
    using NotRespondingFn = std::function<void(std::uint64_t reason)>;
    using RespondingFn = std::function<void()>;
    using ClosedFn = std::function<void(bool ok, const std::string& reason)>;

    NimFfiDispatcher(PollFn poll, LastErrorFn lastError, void* ctx, EventFn onEvent)
        : poll_(poll), lastError_(lastError), ctx_(ctx), onEvent_(onEvent) {}

    // False when the thread could not be started.
    bool start() noexcept {
        try {
            auto self = shared_from_this();
            std::lock_guard<std::mutex> lock(threadMtx_);
            thread_ = std::thread([self] {
                // `thread_` is assigned by now: `stop` may run on this thread.
                { std::lock_guard<std::mutex> started(self->threadMtx_); }
                self->run();
            });
            return true;
        } catch (...) {
            return false;
        }
    }

    // Joins the dispatch thread. Called on the dispatch thread itself (a listener is
    // destroying its context) it detaches instead, and no listener runs once
    // the handler in flight returns.
    void stop() {
        const bool onOwnThread = onDispatchThread();
        if (onOwnThread) detached_.store(true);
        stop_.store(true);
        std::thread thread;
        {
            std::lock_guard<std::mutex> lock(threadMtx_);
            thread = std::move(thread_);
        }
        if (!thread.joinable()) return;
        if (onOwnThread) thread.detach();
        else thread.join();
    }

    // True once the dispatch thread is over: no reply will be delivered any more.
    bool finished() {
        std::lock_guard<std::mutex> lock(waitMtx_);
        return finished_;
    }

    static std::string refusal(LastErrorFn lastError, int rc) {
        const char* text = lastError ? lastError() : nullptr;
        if (text && *text) return text;
        return "FFI request refused (ret code " + std::to_string(rc) + ")";
    }

    template <class T>
    static std::future<Result<T>> ready(Result<T> value) {
        std::promise<Result<T>> promise;
        auto future = promise.get_future();
        promise.set_value(std::move(value));
        return future;
    }

    // Blocking request. `send(&id)` is the `<lib>_<proc>` call.
    template <class T, class Send>
    Result<T> call(Send&& send, std::chrono::milliseconds timeout) {
        auto state = std::make_shared<SyncState>();
        std::uint64_t id = 0;
        std::string refused = submit(send, timeout, false, syncCompletion(state), id);
        if (!refused.empty()) return Result<T>::err(std::move(refused));
        auto raw = wait(*state, id, timeout);
        if (raw.isErr()) return Result<T>::err(raw.error());
        return decodeCborFFI<T>(raw.value());
    }

    // The future is fulfilled by the dispatch thread, or failed by it once `timeout`
    // passed or the context closed. No thread is started.
    template <class T, class Send>
    std::future<Result<T>> callAsync(Send&& send, std::chrono::milliseconds timeout) {
        auto promise = std::make_shared<std::promise<Result<T>>>();
        auto future = promise->get_future();
        std::uint64_t id = 0;
        std::string refused = submit(send, timeout, true, [promise](Result<Bytes> raw) {
            auto out = Result<T>::err("the FFI reply could not be decoded");
            try {
                if (raw.isErr()) out = Result<T>::err(raw.error());
                else out = decodeCborFFI<T>(raw.value());
            } catch (...) {
            }
            try {
                promise->set_value(std::move(out));
            } catch (...) {
            }
        }, id);
        if (!refused.empty()) promise->set_value(Result<T>::err(std::move(refused)));
        return future;
    }

    // The constructor's reply: its id is known before the dispatch loop runs, so the
    // waiter is in place before the reply can be taken out.
    Result<Bytes> startAndWait(std::uint64_t id, std::chrono::milliseconds timeout) {
        auto state = std::make_shared<SyncState>();
        expect(id, timeout, false, syncCompletion(state));
        if (!start()) {
            abandon("could not start the dispatch thread");
        }
        return wait(*state, id, timeout);
    }

    void startAndThen(std::uint64_t id, std::chrono::milliseconds timeout, Completion done) {
        expect(id, timeout, true, std::move(done));
        if (!start()) abandon("could not start the dispatch thread");
    }

    // 0 when `fn` is empty.
    template <class Fn>
    std::uint64_t add(std::uint32_t kind, std::uint64_t nameId, Fn fn) {
        if (!fn) return 0;
        auto held = std::make_shared<Fn>(std::move(fn));
        std::lock_guard<std::mutex> lock(mtx_);
        const std::uint64_t id = nextId_++;
        listeners_.emplace(id, Listener{kind, nameId, std::move(held)});
        return id;
    }

    bool remove(std::uint64_t id) {
        std::shared_ptr<void> released; // a handler's captures die outside the lock
        std::lock_guard<std::mutex> lock(mtx_);
        auto it = listeners_.find(id);
        if (it == listeners_.end()) return false;
        released = std::move(it->second.fn);
        listeners_.erase(it);
        return true;
    }

    // The payload is decoded in full before any handler runs: `msg` belongs to
    // the library and a handler may end the context or poll again.
    template <class T>
    void deliverEvent(const NimFfiMsg& msg) {
        using Fn = std::function<void(const T&)>;
        const auto fns = matching<Fn>(NIMFFI_MSG_EVENT, msg.name_id);
        if (fns.empty()) return;
        CborParser parser;
        CborValue it;
        if (cbor_parser_init(msg.payload, msg.len, 0, &parser, &it) != CborNoError) return;
        T payload{};
        if (decode_cbor(it, payload) != CborNoError) return;
        call(fns, payload);
    }

private:
    static constexpr std::int32_t SliceMs = 250;
    static constexpr const char* ClosedText = "context closed before the reply arrived";

    struct Listener {
        std::uint32_t kind;
        std::uint64_t nameId;
        std::shared_ptr<void> fn; // the std::function type that `kind`/`nameId` imply
    };

    struct Waiter {
        std::chrono::steady_clock::time_point deadline;
        std::chrono::milliseconds timeout;
        bool swept; // the dispatch thread fails it at `deadline`; a blocking caller times itself out
        Completion done;
    };

    struct SyncState {
        std::mutex mtx;
        std::condition_variable cv;
        bool done{false};
        Result<Bytes> result;
    };

    static Completion syncCompletion(const std::shared_ptr<SyncState>& state) {
        return [state](Result<Bytes> raw) {
            std::lock_guard<std::mutex> lock(state->mtx);
            state->result = std::move(raw);
            state->done = true;
            state->cv.notify_all();
        };
    }

    static std::string timeoutText(std::chrono::milliseconds timeout) {
        return "FFI call timed out after " + std::to_string(timeout.count()) + "ms";
    }

    // Clamped: a caller's "forever" must not overflow the clock arithmetic.
    static std::chrono::milliseconds clamp(std::chrono::milliseconds timeout) {
        constexpr std::chrono::milliseconds Max = std::chrono::hours(24 * 365);
        return std::min(std::max(timeout, std::chrono::milliseconds(0)), Max);
    }

    static NimFfiDispatcher*& current() {
        thread_local NimFfiDispatcher* dispatcher = nullptr;
        return dispatcher;
    }

    bool onDispatchThread() { return current() == this; }

    // Empty: the request is queued and `done` runs exactly once. Otherwise why
    // it was refused; `done` never runs.
    // The lock is held across `send`: the reply can be polled before `send`
    // returns, and the dispatch thread takes this lock before it looks a waiter up.
    template <class Send>
    std::string submit(Send& send, std::chrono::milliseconds timeout, bool swept,
                       Completion done, std::uint64_t& id) {
        std::lock_guard<std::mutex> lock(waitMtx_);
        if (finished_) return ClosedText;
        const int rc = send(&id);
        if (rc != NIMFFI_RET_OK) return refusal(lastError_, rc);
        try {
            waiters_.emplace(id, Waiter{std::chrono::steady_clock::now() + clamp(timeout),
                                        timeout, swept, std::move(done)});
        } catch (...) {
            return "out of memory"; // its reply is dropped like any unknown id
        }
        return {};
    }

    void expect(std::uint64_t id, std::chrono::milliseconds timeout, bool swept,
                Completion done) {
        std::lock_guard<std::mutex> lock(waitMtx_);
        waiters_.emplace(id, Waiter{std::chrono::steady_clock::now() + clamp(timeout),
                                    timeout, swept, std::move(done)});
    }

    // False when the waiter is already gone: its completion ran or is running.
    bool forget(std::uint64_t id) {
        Waiter dropped; // its captures die outside the lock
        std::lock_guard<std::mutex> lock(waitMtx_);
        auto it = waiters_.find(id);
        if (it == waiters_.end()) return false;
        dropped = std::move(it->second);
        waiters_.erase(it);
        return true;
    }

    Result<Bytes> wait(SyncState& state, std::uint64_t id, std::chrono::milliseconds timeout) {
        if (onDispatchThread()) {
            // A listener is calling in: only this thread can take the reply out,
            // so poll here, dispatching whatever else arrives meanwhile.
            const auto deadline = std::chrono::steady_clock::now() + clamp(timeout);
            while (!stop_.load() && !closed_) {
                {
                    std::lock_guard<std::mutex> lock(state.mtx);
                    if (state.done) break;
                }
                const auto left = std::chrono::duration_cast<std::chrono::milliseconds>(
                    deadline - std::chrono::steady_clock::now()).count();
                if (left <= 0) break;
                dispatchOnce(static_cast<std::int32_t>(std::min<long long>(left, SliceMs)));
            }
        } else {
            std::unique_lock<std::mutex> lock(state.mtx);
            state.cv.wait_for(lock, clamp(timeout), [&] { return state.done; });
        }
        std::unique_lock<std::mutex> lock(state.mtx);
        if (!state.done) {
            lock.unlock();
            if (forget(id)) {
                if (stop_.load()) return Result<Bytes>::err(ClosedText);
                return Result<Bytes>::err(timeoutText(timeout));
            }
            lock.lock(); // the dispatch thread holds the waiter: its completion is imminent
            state.cv.wait(lock, [&] { return state.done; });
        }
        return std::move(state.result);
    }

    static void finish(Waiter& waiter, Result<Bytes> result) {
        try {
            waiter.done(std::move(result));
        } catch (...) {
        }
    }

    // A reply nobody waits for (its caller timed out) is dropped.
    void deliverReply(const NimFfiMsg& msg) {
        Waiter waiter;
        {
            std::lock_guard<std::mutex> lock(waitMtx_);
            auto it = waiters_.find(msg.id);
            if (it == waiters_.end()) return;
            waiter = std::move(it->second);
            waiters_.erase(it);
        }
        auto result = Result<Bytes>::err("out of memory");
        try {
            if (msg.ret_code == NIMFFI_RET_OK)
                result = Result<Bytes>::ok(Bytes(msg.payload, msg.payload + msg.len));
            else
                result = Result<Bytes>::err(
                    std::string(reinterpret_cast<const char*>(msg.payload), msg.len));
        } catch (...) {
        }
        finish(waiter, std::move(result));
    }

    // So a future never hangs: nobody else watches an async call's deadline.
    void sweepExpired() {
        const auto now = std::chrono::steady_clock::now();
        if (now < nextSweep_) return;
        nextSweep_ = now + std::chrono::milliseconds(SliceMs);
        std::vector<Waiter> expired;
        {
            std::lock_guard<std::mutex> lock(waitMtx_);
            for (auto it = waiters_.begin(); it != waiters_.end();) {
                if (it->second.swept && it->second.deadline <= now) {
                    expired.push_back(std::move(it->second));
                    it = waiters_.erase(it);
                } else {
                    ++it;
                }
            }
        }
        for (auto& waiter : expired)
            finish(waiter, Result<Bytes>::err(timeoutText(waiter.timeout)));
    }

    // Every request still waiting will never be answered.
    void abandon(const std::string& why) {
        std::vector<Waiter> pending;
        {
            std::lock_guard<std::mutex> lock(waitMtx_);
            finished_ = true;
            pending.reserve(waiters_.size());
            for (auto& [id, waiter] : waiters_) pending.push_back(std::move(waiter));
            waiters_.clear();
        }
        for (auto& waiter : pending) finish(waiter, Result<Bytes>::err(why));
    }

    // Copies out under the lock; the handlers then run with the lock released,
    // so a handler may add or remove listeners.
    template <class Fn>
    std::vector<std::shared_ptr<Fn>> matching(std::uint32_t kind, std::uint64_t nameId) {
        std::vector<std::shared_ptr<Fn>> fns;
        std::lock_guard<std::mutex> lock(mtx_);
        for (const auto& [id, l] : listeners_) {
            if (l.kind == kind && l.nameId == nameId)
                fns.push_back(std::static_pointer_cast<Fn>(l.fn));
        }
        return fns;
    }

    template <class Fn, class... Args>
    void call(const std::vector<std::shared_ptr<Fn>>& fns, const Args&... args) {
        for (const auto& fn : fns) {
            if (detached_.load()) return;
            try {
                (*fn)(args...);
            } catch (...) {
                // A listener's exception must not end the dispatch thread.
            }
        }
    }

    // A handler may poll again (a blocking call made inside it), which ends the
    // life of `msg`: whatever a handler is given is copied out first.
    void dispatch(const NimFfiMsg& msg) {
        switch (msg.kind) {
        case NIMFFI_MSG_REPLY:
            deliverReply(msg);
            break;
        case NIMFFI_MSG_EVENT:
            onEvent_(*this, msg);
            break;
        case NIMFFI_MSG_STALE_WARN: {
            const std::uint64_t reqId = msg.id;
            const std::uint64_t elapsedMs = msg.aux;
            call(matching<StaleWarnFn>(NIMFFI_MSG_STALE_WARN, 0), reqId, elapsedMs);
            break;
        }
        case NIMFFI_MSG_NOT_RESPONDING: {
            const std::uint64_t reason = msg.aux;
            call(matching<NotRespondingFn>(NIMFFI_MSG_NOT_RESPONDING, 0), reason);
            break;
        }
        case NIMFFI_MSG_RESPONDING:
            call(matching<RespondingFn>(NIMFFI_MSG_RESPONDING, 0));
            break;
        default:
            break; // a kind from a newer library
        }
    }

    // One poll slice. Dispatch thread only.
    void dispatchOnce(std::int32_t sliceMs) {
        using namespace std::chrono_literals;
        const NimFfiMsg* msg = nullptr;
        const int rc = poll_(ctx_, sliceMs, &msg);
        if (rc == NIMFFI_RET_OK && msg) {
            dispatch(*msg);
        } else if (rc == NIMFFI_RET_CLOSED || rc == NIMFFI_RET_INVALID_CTX) {
            // INVALID_CTX: the context ended between two polls.
            if (rc == NIMFFI_RET_CLOSED && msg && msg->ret_code != NIMFFI_RET_OK) {
                closedOk_ = false;
                if (msg->payload && msg->len > 0)
                    closedReason_.assign(reinterpret_cast<const char*>(msg->payload), msg->len);
            }
            closed_ = true;
            abandon(ClosedText);
            return;
        } else if (rc != NIMFFI_RET_TIMEOUT) {
            std::this_thread::sleep_for(10ms); // BUSY or ERR: try again
        }
        sweepExpired();
    }

    // Ends by failing the waiters, then with the closed notification, whatever
    // stopped it: a closed listener runs exactly once (never after a detach).
    void run() {
        current() = this;
        while (!stop_.load() && !closed_) dispatchOnce(SliceMs);
        abandon(ClosedText);
        call(matching<ClosedFn>(NIMFFI_MSG_CLOSED, 0), closedOk_, closedReason_);
        current() = nullptr;
    }

    const PollFn poll_;
    const LastErrorFn lastError_;
    void* const ctx_;
    const EventFn onEvent_;

    std::mutex mtx_;
    std::map<std::uint64_t, Listener> listeners_; // ordered: handlers run in the order they were added
    std::uint64_t nextId_{1};

    std::mutex waitMtx_;
    std::unordered_map<std::uint64_t, Waiter> waiters_;
    bool finished_{false};

    std::mutex threadMtx_;
    std::thread thread_;
    std::atomic<bool> stop_{false};
    std::atomic<bool> detached_{false};

    // Dispatch thread only.
    bool closed_{false};
    bool closedOk_{true};
    std::string closedReason_;
    std::chrono::steady_clock::time_point nextSweep_{};
};

// The dispatch thread of a library's static context, where `{.ffiStatic.}` replies arrive.
// One per library and process, started by the first static call. Never
// destroyed: the thread may still be polling while the process exits.
class NimFfiStaticDispatcher {
public:
    using StaticCtxFn = void* (*)();

    // The running dispatch thread; a new one when there is none or the static context is
    // another one by now (the library was shut down in between).
    Result<std::shared_ptr<NimFfiDispatcher>> acquire(StaticCtxFn staticCtx, NimFfiDispatcher::PollFn poll,
                                                NimFfiDispatcher::LastErrorFn lastError) {
        using Ret = Result<std::shared_ptr<NimFfiDispatcher>>;
        std::lock_guard<std::mutex> lock(mtx_);
        void* token = staticCtx();
        if (!token) return Ret::err(NimFfiDispatcher::refusal(lastError, NIMFFI_RET_ERR));
        if (dispatcher_ && token == token_ && !dispatcher_->finished()) return Ret::ok(dispatcher_);
        stopLocked();
        auto dispatcher = std::make_shared<NimFfiDispatcher>(poll, lastError, token, &noEvents);
        if (!dispatcher->start()) return Ret::err("could not start the dispatch thread");
        dispatcher_ = dispatcher;
        token_ = token;
        return Ret::ok(std::move(dispatcher));
    }

    // Fails the static calls still waiting and joins the thread, which takes up
    // to one poll slice.
    void stop() {
        std::lock_guard<std::mutex> lock(mtx_);
        stopLocked();
    }

private:
    static void noEvents(NimFfiDispatcher&, const NimFfiMsg&) {}

    void stopLocked() {
        if (!dispatcher_) return;
        dispatcher_->stop();
        dispatcher_.reset();
        token_ = nullptr;
    }

    std::mutex mtx_;
    std::shared_ptr<NimFfiDispatcher> dispatcher_;
    void* token_{nullptr};
};

#endif // NIM_FFI_DISPATCHER_HPP_INCLUDED
