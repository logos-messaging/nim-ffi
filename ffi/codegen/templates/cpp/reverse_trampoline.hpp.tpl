    struct {{BOX}} {
        void* ctx = nullptr;
        {{FN_TYPE}} fn;
    };
    static void {{NAME}}ImplRelease(void* ud) {
        delete static_cast<{{BOX}}*>(ud);
    }
    // noexcept: an exception must not unwind into the library's worker thread.
    static void {{NAME}}ImplTrampoline(std::uint64_t call_id, const std::uint8_t* args, std::size_t len, void* ud) noexcept {
        auto* box = static_cast<{{BOX}}*>(ud);
        {{CALL}} call{box->ctx, call_id};
        try {
            if (!box->fn) { call.failRaw("no C++ impl callable"); return; }
{{INVOKE}}
        } catch (const std::exception& e) {
            call.failRaw(e.what()); // dropped if the impl already replied
        } catch (...) {
            call.failRaw("host impl threw");
        }
    }
