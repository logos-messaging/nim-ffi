#include "nimtimer.hpp"
#include <iostream>
#include <future>

int main() {
    try {
        auto ctx = NimTimerCtx::create(TimerConfig{"cpp-demo"});
        std::cout << "[1] Context created\n";

        auto versionFuture = ctx.versionAsync();
        auto echo1Future = ctx.echoAsync(EchoRequest{"hello from C++", 200});
        auto echo2Future = ctx.echoAsync(EchoRequest{"second C++ request", 50});

        auto version = versionFuture.get();
        std::cout << "[2] Version: " << version << "\n";

        auto echo = echo1Future.get();
        std::cout << "[3] Echo 1: echoed=" << echo.echoed
                  << ", timerName=" << echo.timerName << "\n";

        auto echo2 = echo2Future.get();
        std::cout << "[4] Echo 2: echoed=" << echo2.echoed
                  << ", timerName=" << echo2.timerName << "\n";

        auto complexReq = ComplexRequest{
            std::vector<EchoRequest>{EchoRequest{"one", 10}, EchoRequest{"two", 20}},
            std::vector<std::string>{"fast", "async"},
            std::optional<std::string>("extra note"),
            std::optional<int64_t>(3)
        };

        auto complexFuture = ctx.complexAsync(complexReq);
        auto complex = complexFuture.get();
        std::cout << "[5] Complex: summary=" << complex.summary
                  << ", itemCount=" << complex.itemCount
                  << ", hasNote=" << complex.hasNote << "\n";

        std::cout << "\nDone.\n";
    } catch (const std::exception& ex) {
        std::cerr << "Error: " << ex.what() << "\n";
        return 1;
    }
    return 0;
}
