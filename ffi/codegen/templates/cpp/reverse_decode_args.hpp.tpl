    template <class T>
    static CborError decodeReverseArgs_(const std::uint8_t* data, std::size_t len, T& out) {
        CborParser parser; CborValue it;
        CborError err = cbor_parser_init(data, len, 0, &parser, &it);
        if (err) return err;
        return decode_cbor(it, out);
    }
