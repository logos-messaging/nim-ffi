    /// The context stopped answering. `reason` is NIMFFI_NOT_RESPONDING_HEARTBEAT
    /// (the FFI thread's heartbeat stalled) or NIMFFI_NOT_RESPONDING_EVENT_QUEUE_FULL
    /// (the event queue overflowed; requests are refused until the context is recycled).
    ListenerHandle addNotRespondingListener(std::function<void(std::uint64_t reason)> handler) {
        return ListenerHandle{pump_->add(NIMFFI_MSG_NOT_RESPONDING, 0, std::move(handler))};
    }

    /// The FFI thread's heartbeat resumed after a NIMFFI_NOT_RESPONDING_HEARTBEAT.
    ListenerHandle addRespondingListener(std::function<void()> handler) {
        return ListenerHandle{pump_->add(NIMFFI_MSG_RESPONDING, 0, std::move(handler))};
    }

    /// The context is gone: the last call any listener of this context receives,
    /// exactly once. `ok` is false when the library gave the context up, and
    /// `reason` then says why. Not called when a listener destroys the context
    /// from the pump thread.
    ListenerHandle addClosedListener(std::function<void(bool ok, const std::string& reason)> handler) {
        return ListenerHandle{pump_->add(NIMFFI_MSG_CLOSED, 0, std::move(handler))};
    }

    /// Unregister any listener added above. False when the handle is unknown.
    /// Safe from any thread, a listener included. A delivery already in flight
    /// may still reach the removed listener once, so keep what it captures alive
    /// until then.
    bool removeEventListener(ListenerHandle handle) {
        if (handle.id == 0) return false;
        return pump_->remove(handle.id);
    }
