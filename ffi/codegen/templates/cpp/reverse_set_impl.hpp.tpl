    Result<void> set{{PASCAL}}Impl({{FN_TYPE}} fn) {
        auto* raw = new {{BOX}}{std::move(fn)};
        // The library owns the box now: it deletes it once no invocation runs it.
        const int rc = {{LIB}}_set_{{WIRE}}_impl(ptr_, &{{CTX}}::{{NAME}}ImplTrampoline, raw, &{{CTX}}::{{NAME}}ImplRelease);
        if (rc != NIMFFI_RET_OK) {
            delete raw; // refused: still ours
            return Result<void>::err(std::string("set {{WIRE}} impl: ") + nimffiRetName(rc));
        }
        return Result<void>::ok();
    }

    Result<void> clear{{PASCAL}}Impl() {
        const int rc = {{LIB}}_set_{{WIRE}}_impl(ptr_, nullptr, nullptr, nullptr);
        if (rc != NIMFFI_RET_OK) return Result<void>::err(std::string("clear {{WIRE}} impl: ") + nimffiRetName(rc));
        return Result<void>::ok();
    }
