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
            // `{{LIB}}_destroy` is non-blocking at the C ABI: it parks the
            // context for reuse and reports the outcome via the callback. Block
            // here until that callback fires so the pool slot is fully drained
            // and parked before this object goes away — otherwise a rapid
            // create/destroy churn could outrun the recycle and exhaust the pool.
            (void)ffi_call_([this](FFICallback cb, void* ud) {
                return {{LIB}}_destroy(ptr_, cb, ud);
            }, timeout_);
            ptr_ = nullptr;
        }
    }

    {{CTX}}(const {{CTX}}&) = delete;
    {{CTX}}& operator=(const {{CTX}}&) = delete;
    {{CTX}}({{CTX}}&&) = delete;
    {{CTX}}& operator=({{CTX}}&&) = delete;
