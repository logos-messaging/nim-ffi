#include "nimtimer.hpp"
#include <iostream>

int main() {
    try {
        auto ctx = NimTimerCtx::create(TimerConfig{"cpp-demo"});
        std::cout << "[1] Context created\n";

        auto version = ctx.version();
        std::cout << "[2] Version: " << version << "\n";

        auto echo = ctx.echo(EchoRequest{"hello from C++", 200});
        std::cout << "[3] Echo 1: echoed=" << echo.echoed
                  << ", timerName=" << echo.timerName << "\n";

        auto echo2 = ctx.echo(EchoRequest{"second C++ request", 50});
        std::cout << "[4] Echo 2: echoed=" << echo2.echoed
                  << ", timerName=" << echo2.timerName << "\n";

        auto complexReq = ComplexRequest{
            std::vector<EchoRequest>{EchoRequest{"one", 10}, EchoRequest{"two", 20}},
            std::vector<std::string>{"fast", "async"},
            std::optional<std::string>("extra note"),
            std::optional<int64_t>(3)
        };
        auto complex = ctx.complex(complexReq);
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
