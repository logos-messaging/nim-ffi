//@@create
    static {{RET}} create({{PARAMS}}) {
        const auto ffi_req_ = {{REQ}};
        auto ffi_enc_ = encodeCborFFI(ffi_req_);
        if (ffi_enc_.isErr()) return {{RET}}::err("{{NAME}}: could not encode the request: " + ffi_enc_.error());
        auto ffi_host_ = std::make_unique<nim_ffi::Host>(nim_ffi::Library{::{{PROC}}, ::{{LIB}}_destroy, ::{{LIB}}_poll, ::{{LIB}}_poll_fd, ::{{LIB}}_reverse_reply});
        const auto ffi_reply_ = ffi_host_->create(ffi_enc_.value(), timeout);
        if (ffi_reply_.ret != NIMFFI_RET_OK) return {{RET}}::err(ffiPollError_("{{NAME}}", ffi_reply_));
        return {{RET}}::ok(std::unique_ptr<{{CTX}}>(new {{CTX}}(std::move(ffi_host_), timeout)));
    }
//@@method
    {{STATIC}}{{RET}} {{NAME}}({{PARAMS}}){{CONST}} {
        const auto ffi_req_ = {{REQ}};
        auto ffi_enc_ = encodeCborFFI(ffi_req_);
        if (ffi_enc_.isErr()) return {{RET}}::err("{{NAME}}: could not encode the request: " + ffi_enc_.error());
        const auto ffi_reply_ = {{HOST}}.call(::{{PROC}}, ffi_enc_.value(), {{TIMEOUT}});
        if (ffi_reply_.ret != NIMFFI_RET_OK) return {{RET}}::err(ffiPollError_("{{NAME}}", ffi_reply_));
        return decodeCborFFI<{{VALUE}}>(ffi_reply_.payload);
    }
//@@listener
    ListenerHandle {{NAME}}(std::function<void(const {{PAYLOAD}}&)> handler) {
        return addListener_("{{WIRE}}", [h = std::move(handler)](const std::uint8_t* p, std::size_t n) {
            auto decoded = decodeCborFFI<{{PAYLOAD}}>(std::vector<std::uint8_t>(p, p + n));
            if (decoded.isOk()) {
                h(decoded.value());
            } else {
                std::fprintf(stderr, "nim_ffi: event {{WIRE}}: could not decode the payload: %s\n", decoded.error().c_str());
            }
        });
    }
