    // Answer token for one `{{WIRE}}` call (copyable). Reply once, from any thread;
    // a late or second reply is dropped, and one after destroy returns an error.
    struct {{CALL}} {
        void* ctx = nullptr;
        std::uint64_t id = 0;
{{REPLY}}
        Result<void> fail(const std::string& msg) const {
            const int rc = {{LIB}}_reverse_reply(ctx, id, 1, reinterpret_cast<const std::uint8_t*>(msg.data()), msg.size());
            if (rc != NIMFFI_RET_OK) return Result<void>::err(std::string("fail {{WIRE}}: ") + nimffiRetName(rc));
            return Result<void>::ok();
        }
        // Allocation-free, for reporting from a catch block.
        bool failRaw(const char* msg) const noexcept {
            return {{LIB}}_reverse_reply(ctx, id, 1, reinterpret_cast<const std::uint8_t*>(msg), msg ? std::strlen(msg) : 0) == NIMFFI_RET_OK;
        }
    };
