    // Answer token for one `{{WIRE}}` call: a trivially copyable {context token,
    // call id} pair. Copy it anywhere and reply once, from any thread, before the
    // call's deadline; a late or second reply is dropped, and a reply after the
    // context is gone returns false.
    struct {{CALL}} {
        void* ctx = nullptr;
        std::uint64_t id = 0;
{{REPLY}}
        bool fail(const std::string& msg) const {
            return {{LIB}}_reverse_reply(ctx, id, 1, reinterpret_cast<const std::uint8_t*>(msg.data()), msg.size()) == 0;
        }
        // Allocation-free, for reporting from a catch block.
        bool failRaw(const char* msg) const noexcept {
            return {{LIB}}_reverse_reply(ctx, id, 1, reinterpret_cast<const std::uint8_t*>(msg), msg ? std::strlen(msg) : 0) == 0;
        }
    };
