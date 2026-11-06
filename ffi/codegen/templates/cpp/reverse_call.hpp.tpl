    // Answer token for one `{{WIRE}}` call (copyable). Reply once, from any thread;
    // a late or second reply is dropped, and one after destroy returns false.
    struct {{CALL}} {
        void* ctx = nullptr;
        std::uint64_t id = 0;
{{REPLY}}
        bool fail(const std::string& msg) const {
            return {{LIB}}_reverse_reply(ctx, id, 1, reinterpret_cast<const std::uint8_t*>(msg.data()), msg.size()) == NIMFFI_RET_OK;
        }
        // Allocation-free, for reporting from a catch block.
        bool failRaw(const char* msg) const noexcept {
            return {{LIB}}_reverse_reply(ctx, id, 1, reinterpret_cast<const std::uint8_t*>(msg), msg ? std::strlen(msg) : 0) == NIMFFI_RET_OK;
        }
    };
