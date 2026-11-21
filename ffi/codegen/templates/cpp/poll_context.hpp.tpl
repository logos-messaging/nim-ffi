class {{CTX}} {
public:
    {{CTX}}(const {{CTX}}&) = delete;
    {{CTX}}& operator=(const {{CTX}}&) = delete;

{{CREATE_METHODS}}
    // Events and reverse calls are served by whoever runs the library's queue, on that
    // thread; calls such as the methods below serve it themselves while they wait.
    //   runLoop(): blocks this thread and serves until stop(). For an app with no loop:
    //               ctx->addOnTickListener(...);  ctx->runLoop();   // or on a thread of yours
    //   poll():    serves what is waiting and returns at once; call it once per
    //             iteration or tick of a loop of your own, or, in a loop with descriptor
    //             watchers (Qt, libuv, asio, ...), when fd() is readable.
    // Handlers must return quickly. host() is the underlying nim_ffi::Host, for
    // reverse-call handlers (onReverseCall / reverseReply) and the slow-handler hook.
    // For epoll, kqueue and Windows wiring see nim_ffi_host.hpp.
#ifndef NIM_FFI_NO_RUNLOOP
    void runLoop() { host_->runLoop(); }
#endif
    size_t poll() { return host_->poll(); }
    void stop() { host_->stop(); }
    nim_ffi::Host& host() { return *host_; }
    int64_t fd() const { return host_->fd(); }

{{METHODS}}
//@events
    struct ListenerHandle { std::uint64_t id = 0; };

{{EVENT_METHODS}}
    bool removeEventListener(ListenerHandle handle) {
        std::lock_guard<std::mutex> lock(listenersMu_);
        return std::erase_if(listeners_, [&](const Listener_& l) { return l.id == handle.id; }) > 0;
    }

//@end
//@reverse
    // The library asks the host questions: answer them with host().onReverseCall(...)
    // and host().reverseReply(...); a call with no handler is refused.

//@end
private:
//@static
    // Static procs reply on the library's own context, which it owns: one host, kept for
    // the process, attached to it. Attached again whenever it is not (the library was not
    // ready on the first call, or the context was closed since).
    static nim_ffi::Host& staticHost_() {
        static nim_ffi::Host* host = new nim_ffi::Host(nim_ffi::Library{nullptr, nullptr, ::{{LIB}}_poll, ::{{LIB}}_poll_fd, ::{{LIB}}_reverse_reply});
        if (!host->alive()) host->attach(::{{LIB}}_static_ctx());
        return *host;
    }

//@end
//@events
    using EventFn_ = std::function<void(const std::uint8_t*, std::size_t)>;
    struct Listener_ { std::uint64_t id; std::uint64_t nameId; std::shared_ptr<EventFn_> fn; };

    ListenerHandle addListener_(const char* wireName, EventFn_ fn) {
        std::lock_guard<std::mutex> lock(listenersMu_);
        const auto id = ++nextListenerId_;
        listeners_.push_back(Listener_{id, nimffi_name_id(wireName), std::make_shared<EventFn_>(std::move(fn))});
        return ListenerHandle{id};
    }

    // Runs on the thread that pumps; the handlers are copied out so one may add or remove listeners.
    void dispatchEvent_(std::uint64_t nameId, const std::uint8_t* p, std::size_t n) {
        std::vector<std::shared_ptr<EventFn_>> matched;
        {
            std::lock_guard<std::mutex> lock(listenersMu_);
            for (const auto& l : listeners_) if (l.nameId == nameId) matched.push_back(l.fn);
        }
        for (const auto& fn : matched) (*fn)(p, n);
    }

//@end
    {{CTX}}(std::unique_ptr<nim_ffi::Host> host, std::chrono::milliseconds timeout)
        : timeout_(timeout), host_(std::move(host)) {
//@events
        host_->onEvent([this](std::uint64_t id, const std::uint8_t* p, std::size_t n) { dispatchEvent_(id, p, n); });
//@end
    }

    std::chrono::milliseconds timeout_;
//@events
    std::mutex listenersMu_;
    std::vector<Listener_> listeners_;
    std::uint64_t nextListenerId_ = 0;
//@end
    // Last, so the context is destroyed before the state its handlers use.
    std::unique_ptr<nim_ffi::Host> host_;
};
