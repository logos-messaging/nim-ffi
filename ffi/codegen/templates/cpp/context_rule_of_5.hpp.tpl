    // Rule of Five: because this class owns a raw resource (the {{LIB}}
    // context pointer freed in the destructor), the compiler-generated copy
    // and move special members would do the wrong thing — copies would
    // double-free, and a default move would leave both objects pointing at
    // the same context. So we define all five special members explicitly:
    //   1. destructor          — releases the context.
    //   2. copy constructor    — deleted; contexts are not copyable.
    //   3. copy assignment     — deleted; same reason.
    //   4. move constructor    — transfers ownership, nulls the source.
    //   5. move assignment     — destroys the current context, then
    //                            transfers ownership from `other`.
    // See: https://en.cppreference.com/w/cpp/language/rule_of_three
    ~{{CTX}}() {
        if (ptr_) {
            {{LIB}}_destroy(ptr_);
            ptr_ = nullptr;
        }
    }

    {{CTX}}(const {{CTX}}&) = delete;
    {{CTX}}& operator=(const {{CTX}}&) = delete;

    {{CTX}}({{CTX}}&& other) noexcept : ptr_(other.ptr_), timeout_(other.timeout_) {
        other.ptr_ = nullptr;
    }
    {{CTX}}& operator=({{CTX}}&& other) noexcept {
        if (this != &other) {
            if (ptr_) {{LIB}}_destroy(ptr_);
            ptr_ = other.ptr_;
            timeout_ = other.timeout_;
            other.ptr_ = nullptr;
        }
        return *this;
    }
