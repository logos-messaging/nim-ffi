    // Special-member policy: this class owns a {{LIB}} context, which in
    // turn owns the library's worker thread(s) and internal state. Moving
    // such an object out from under a caller silently tears that state
    // down and is easy to misuse (e.g. storing in a container that
    // relocates its elements). It also has no clean analogue in the other
    // binding languages we generate. So copies and moves are both
    // deleted; ownership is transferred via {{CTX}}::create returning a
    // std::unique_ptr<{{CTX}}>. The destructor still releases the
    // context.
    ~{{CTX}}() {
        if (ptr_) {
            // Before the pump stops: the teardown may still emit events, and the
            // poll the pump is blocked in wakes with NIMFFI_RET_CLOSED.
            {{LIB}}_destroy(ptr_);
            ptr_ = nullptr;
        }
        // A listener may destroy its own context: that runs on the pump thread,
        // which cannot join itself and owns its own reference to `pump_`.
        const bool onPump = std::this_thread::get_id() == pumpThread_.get_id();
        pump_->stop(onPump);
        if (onPump) {
            pumpThread_.detach();
        } else if (pumpThread_.joinable()) {
            pumpThread_.join();
        }
    }

    {{CTX}}(const {{CTX}}&) = delete;
    {{CTX}}& operator=(const {{CTX}}&) = delete;
    {{CTX}}({{CTX}}&&) = delete;
    {{CTX}}& operator=({{CTX}}&&) = delete;
