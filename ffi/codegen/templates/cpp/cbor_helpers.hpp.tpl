template<typename T>
inline std::vector<std::uint8_t> encodeCborFfi(const T& value) {
    return nlohmann::json::to_cbor(nlohmann::json(value));
}

template<typename T>
inline T decodeCborFfi(const std::vector<std::uint8_t>& bytes) {
    try {
        return nlohmann::json::from_cbor(bytes).get<T>();
    } catch (const nlohmann::json::exception& e) {
        throw std::runtime_error(std::string("FFI CBOR decode failed: ") + e.what());
    }
}
