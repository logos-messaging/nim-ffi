    static std::future<Result<std::unique_ptr<{{CTX}}>>> createAsync({{PARAMS}}) {
        using Ret = Result<std::unique_ptr<{{CTX}}>>;
        const auto ffi_req_ = {{REQ_INIT}};
        auto ffi_enc_ = encodeCborFFI(ffi_req_);
        if (ffi_enc_.isErr()) return NimFfiDispatcher::ready(Ret::err(ffi_enc_.error()));
        const auto& ffi_req_bytes_ = ffi_enc_.value();
        void* ffi_ptr_ = nullptr;
        std::uint64_t ffi_id_ = 0;
        const int ffi_rc_ = {{CREATE}}(ffi_req_bytes_.data(), ffi_req_bytes_.size(), &ffi_ptr_, &ffi_id_);
        if (ffi_rc_ != NIMFFI_RET_OK)
            return NimFfiDispatcher::ready(Ret::err(NimFfiDispatcher::refusal(&{{LIB}}_last_error, ffi_rc_)));
        auto ffi_promise_ = std::make_shared<std::promise<Ret>>();
        auto ffi_future_ = ffi_promise_->get_future();
        // The completion owns the context until the reply says it was built
        // (shared: a std::function must be copyable).
        auto ffi_held_ = std::make_shared<std::unique_ptr<{{CTX}}>>(new {{CTX}}(ffi_ptr_, timeout));
        auto ffi_dispatcher_ = (*ffi_held_)->dispatcher_;
        ffi_dispatcher_->startAndThen(ffi_id_, timeout,
            [ffi_held_, ffi_promise_](Result<NimFfiDispatcher::Bytes> ffi_raw_) {
                auto ffi_ctx_ = std::move(*ffi_held_);
                if (ffi_raw_.isErr()) {
                    ffi_ctx_.reset(); // a failed construction still claimed the context
                    ffi_promise_->set_value(Ret::err(ffi_raw_.error()));
                } else {
                    ffi_promise_->set_value(Ret::ok(std::move(ffi_ctx_)));
                }
            });
        return ffi_future_;
    }
