    Result<void> emit{{PASCAL}}({{PARAMS}}) const {
        const auto payload_ = {{PAYLOAD}};
        auto enc = encodeCborFFI(payload_);
        if (enc.isErr()) return Result<void>::err("emit {{WIRE}}: " + enc.error());
        const auto& b = enc.value();
        const int rc = {{LIB}}_emit_{{WIRE}}(ptr_, b.data(), b.size());
        if (rc != NIMFFI_RET_OK) return Result<void>::err(std::string("emit {{WIRE}}: ") + nimffiRetName(rc));
        return Result<void>::ok();
    }
