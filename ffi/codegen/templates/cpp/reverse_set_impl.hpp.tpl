    bool set{{PASCAL}}Impl({{FN_TYPE}} fn) {
        auto* raw = new {{BOX}}{std::move(fn)};
        // The library owns the box now: it deletes it once no invocation runs it.
        if ({{LIB}}_set_{{WIRE}}_impl(ptr_, &{{CTX}}::{{NAME}}ImplTrampoline, raw, &{{CTX}}::{{NAME}}ImplRelease) != 0) {
            delete raw; // refused: still ours
            return false;
        }
        return true;
    }

    bool clear{{PASCAL}}Impl() {
        return {{LIB}}_set_{{WIRE}}_impl(ptr_, nullptr, nullptr, nullptr) == 0;
    }
