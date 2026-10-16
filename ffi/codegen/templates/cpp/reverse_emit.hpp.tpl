    bool emit{{PASCAL}}({{PARAMS}}) const {
        const auto payload_ = {{PAYLOAD}};
        auto enc = encodeCborFFI(payload_);
        if (enc.isErr()) return false;
        const auto& b = enc.value();
        return {{LIB}}_emit_{{WIRE}}(ptr_, b.data(), b.size()) == 0;
    }
