// ============================================================
// Message pump
// ============================================================
// The library never calls into the host for an event. Each context owns one
// pump thread that takes the messages out through `<lib>_poll` and calls the
// listeners registered on it.
// Guarded so two nim-ffi headers can share a translation unit.
#ifndef NIM_FFI_PUMP_HPP_INCLUDED
#define NIM_FFI_PUMP_HPP_INCLUDED

class NimFfiPump {
public:
    using PollFn = int (*)(void* ctx, std::int32_t timeout_ms, const NimFfiMsg** msg);
    // Decodes one NIMFFI_MSG_EVENT and delivers it; generated per library.
    using EventFn = void (*)(NimFfiPump& pump, const NimFfiMsg& msg);

    using NotRespondingFn = std::function<void(std::uint64_t reason)>;
    using RespondingFn = std::function<void()>;
    using ClosedFn = std::function<void(bool ok, const std::string& reason)>;

    // Returns a non-joinable thread when the thread could not be started.
    static std::thread start(std::shared_ptr<NimFfiPump> pump, PollFn poll,
                             void* ctx, EventFn onEvent) noexcept {
        try {
            return std::thread([pump = std::move(pump), poll, ctx, onEvent] {
                pump->run(poll, ctx, onEvent);
            });
        } catch (...) {
            return std::thread();
        }
    }

    // `detached`: the owner is going away on the pump thread itself, so no
    // listener may run once the handler in flight returns.
    void stop(bool detached) {
        if (detached) detached_.store(true);
        stop_.store(true);
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
    // the library and a handler may end the context.
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
    struct Listener {
        std::uint32_t kind;
        std::uint64_t nameId;
        std::shared_ptr<void> fn; // the std::function type that `kind`/`nameId` imply
    };

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
                // A listener's exception must not end the pump thread.
            }
        }
    }

    void dispatch(const NimFfiMsg& msg, EventFn onEvent) {
        switch (msg.kind) {
        case NIMFFI_MSG_EVENT:
            onEvent(*this, msg);
            break;
        case NIMFFI_MSG_NOT_RESPONDING:
            call(matching<NotRespondingFn>(NIMFFI_MSG_NOT_RESPONDING, 0), msg.aux);
            break;
        case NIMFFI_MSG_RESPONDING:
            call(matching<RespondingFn>(NIMFFI_MSG_RESPONDING, 0));
            break;
        default:
            break; // a kind from a newer library
        }
    }

    // Ends with the closed notification whatever stopped it, so a closed
    // listener runs exactly once (never after a `stop(true)`).
    void run(PollFn poll, void* ctx, EventFn onEvent) {
        using namespace std::chrono_literals;
        bool ok = true;
        std::string reason;
        while (!stop_.load()) {
            const NimFfiMsg* msg = nullptr;
            const int rc = poll(ctx, 250, &msg);
            if (rc == NIMFFI_RET_OK && msg) {
                dispatch(*msg, onEvent);
            } else if (rc == NIMFFI_RET_CLOSED) {
                ok = !msg || msg->ret_code == NIMFFI_RET_OK;
                if (!ok && msg->payload && msg->len > 0)
                    reason.assign(reinterpret_cast<const char*>(msg->payload), msg->len);
                break;
            } else if (rc == NIMFFI_RET_INVALID_CTX) {
                break; // the context ended between two polls
            } else if (rc != NIMFFI_RET_TIMEOUT) {
                std::this_thread::sleep_for(10ms); // BUSY or ERR: try again
            }
        }
        call(matching<ClosedFn>(NIMFFI_MSG_CLOSED, 0), ok, reason);
    }

    std::mutex mtx_;
    std::map<std::uint64_t, Listener> listeners_; // ordered: handlers run in the order they were added
    std::uint64_t nextId_{1};
    std::atomic<bool> stop_{false};
    std::atomic<bool> detached_{false};
};

#endif // NIM_FFI_PUMP_HPP_INCLUDED
