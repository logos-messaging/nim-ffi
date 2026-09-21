    /// Request `reqId` is still running after `elapsedMs`; its reply still comes.
    ListenerHandle addStaleWarnListener(std::function<void(std::uint64_t reqId, std::uint64_t elapsedMs)> handler) {
        return ListenerHandle{dispatcher_->add(NIMFFI_MSG_STALE_WARN, 0, std::move(handler))};
    }

    /// The context stopped answering. `reason` is NIMFFI_NOT_RESPONDING_HEARTBEAT
    /// (the FFI thread's heartbeat stalled) or NIMFFI_NOT_RESPONDING_EVENT_QUEUE_FULL
    /// (the event queue overflowed; requests are refused until the context is recycled).
    ListenerHandle addNotRespondingListener(std::function<void(std::uint64_t reason)> handler) {
        return ListenerHandle{dispatcher_->add(NIMFFI_MSG_NOT_RESPONDING, 0, std::move(handler))};
    }

    /// The FFI thread's heartbeat resumed after a NIMFFI_NOT_RESPONDING_HEARTBEAT.
    ListenerHandle addRespondingListener(std::function<void()> handler) {
        return ListenerHandle{dispatcher_->add(NIMFFI_MSG_RESPONDING, 0, std::move(handler))};
    }

    /// The context is gone: the last call any listener of this context receives,
    /// exactly once. Every call still waiting for its reply has failed by then.
    /// `ok` is false when the library gave the context up, and `reason` then says
    /// why. Not called when a listener destroys the context from the dispatch thread.
    ListenerHandle addClosedListener(std::function<void(bool ok, const std::string& reason)> handler) {
        return ListenerHandle{dispatcher_->add(NIMFFI_MSG_CLOSED, 0, std::move(handler))};
    }

    /// Unregister any listener added above. False when the handle is unknown.
    /// Safe from any thread, a listener included. A delivery already in flight
    /// may still reach the removed listener once, so keep what it captures alive
    /// until then.
    bool removeEventListener(ListenerHandle handle) {
        if (handle.id == 0) return false;
        return dispatcher_->remove(handle.id);
    }
