    static Result<std::unique_ptr<{{CTX}}>> create({{PARAMS}}) {
        using Ret = Result<std::unique_ptr<{{CTX}}>>;
        const auto ffi_req_ = {{REQ_INIT}};
        auto ffi_enc_ = encodeCborFFI(ffi_req_);
        if (ffi_enc_.isErr()) return Ret::err(ffi_enc_.error());
        const auto& ffi_req_bytes_ = ffi_enc_.value();
        void* ffi_ptr_ = nullptr;
        std::uint64_t ffi_id_ = 0;
        const int ffi_rc_ = {{CREATE}}(ffi_req_bytes_.data(), ffi_req_bytes_.size(), &ffi_ptr_, &ffi_id_);
        if (ffi_rc_ != NIMFFI_RET_OK)
            return Ret::err(NimFfiPump::refusal(&{{LIB}}_last_error, ffi_rc_));
        // `new` (not make_unique) so the constructor can stay private.
        auto ffi_ctx_ = std::unique_ptr<{{CTX}}>(new {{CTX}}(ffi_ptr_, timeout));
        // Whether the construction worked is a reply on the new context. A failed
        // one still claimed it: the destructor of `ffi_ctx_` releases it.
        auto ffi_raw_ = ffi_ctx_->pump_->startAndWait(ffi_id_, timeout);
        if (ffi_raw_.isErr()) return Ret::err(ffi_raw_.error());
        return Ret::ok(std::move(ffi_ctx_));
    }
