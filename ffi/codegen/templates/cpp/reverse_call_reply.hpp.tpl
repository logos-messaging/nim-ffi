        // A reply that does not encode still answers the call, with the reason
        // as the error, so the library does not wait out its timeout.
        Result<void> reply(const {{REPLY_TYPE}}& r) const {
            auto enc = encodeCborFFI(r);
            if (enc.isErr()) {
                (void)failRaw(enc.error().c_str());
                return Result<void>::err("reply {{WIRE}}: " + enc.error());
            }
            const auto& b = enc.value();
            const int rc = {{LIB}}_reverse_reply(ctx, id, 0, b.data(), b.size());
            if (rc != NIMFFI_RET_OK) return Result<void>::err(std::string("reply {{WIRE}}: ") + nimffiRetName(rc));
            return Result<void>::ok();
        }
