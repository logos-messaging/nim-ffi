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
