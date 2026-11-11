        Result<void> reply() const {
            const int rc = {{LIB}}_reverse_reply(ctx, id, 0, nullptr, 0);
            if (rc != NIMFFI_RET_OK) return Result<void>::err(std::string("reply {{WIRE}}: ") + nimffiRetName(rc));
            return Result<void>::ok();
        }
