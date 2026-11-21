// ============================================================
// Answering the library's reverse calls
// ============================================================

#ifndef NIM_FFI_RESPONDER_HPP_INCLUDED
#define NIM_FFI_RESPONDER_HPP_INCLUDED
#include <unordered_map>

namespace nim_ffi_detail {
// What every copy of a Responder shares: the call, and whether it was answered.
class ReverseAnswer {
public:
    ReverseAnswer(std::weak_ptr<nim_ffi::Host> host, std::uint64_t callId)
        : host_(std::move(host)), callId_(callId) {}
    ~ReverseAnswer() {
        sendText(NIMFFI_RET_ERR, "the handler dropped the call without answering");
    }
    void sendText(int ret, const std::string& text) {
        send(ret, reinterpret_cast<const std::uint8_t*>(text.data()), text.size());
    }
    void sendBytes(int ret, const std::vector<std::uint8_t>& bytes) {
        send(ret, bytes.data(), bytes.size());
    }

private:
    void send(int ret, const std::uint8_t* p, std::size_t n) {
        if (answered_.exchange(true)) return;
        if (auto host = host_.lock()) host->reverseReply(callId_, ret, p, n);
    }
    std::weak_ptr<nim_ffi::Host> host_;
    std::uint64_t callId_;
    std::atomic<bool> answered_{false};
};
} // namespace nim_ffi_detail

// The answer to one reverse call, for the handler to give now or later, from any thread.
// Cheap to copy: the first ok() or err() of any copy answers and the rest are ignored.
// If every copy is dropped without answering, the library is told at once instead of
// waiting out its deadline. Answering after the context is gone does nothing.
template <class T>
class Responder {
public:
    Responder(std::weak_ptr<nim_ffi::Host> host, std::uint64_t callId)
        : answer_(std::make_shared<nim_ffi_detail::ReverseAnswer>(std::move(host), callId)) {}
    void ok(const T& value) const {
        auto encoded = encodeCborFFI(value);
        if (encoded.isErr()) {
            answer_->sendText(NIMFFI_RET_ERR, "could not encode the answer: " + encoded.error());
            return;
        }
        answer_->sendBytes(NIMFFI_RET_OK, encoded.value());
    }
    void err(const std::string& message) const { answer_->sendText(NIMFFI_RET_ERR, message); }

private:
    std::shared_ptr<nim_ffi_detail::ReverseAnswer> answer_;
};

template <>
class Responder<void> {
public:
    Responder(std::weak_ptr<nim_ffi::Host> host, std::uint64_t callId)
        : answer_(std::make_shared<nim_ffi_detail::ReverseAnswer>(std::move(host), callId)) {}
    void ok() const { answer_->sendBytes(NIMFFI_RET_OK, {0xf6}); }
    void err(const std::string& message) const { answer_->sendText(NIMFFI_RET_ERR, message); }

private:
    std::shared_ptr<nim_ffi_detail::ReverseAnswer> answer_;
};
#endif // NIM_FFI_RESPONDER_HPP_INCLUDED
