// Driver for the GENERATED native C++ bindings (my_timer_native.hpp).
// Uses the native (zero-serialization) ABI: typed structs in, typed structs out.
#include "my_timer_native.hpp"

#include <iostream>

int main() {
  try {
    my_timer::My_timerNode node(my_timer::TimerConfig{"cpp-native-gen"});
    std::cout << "version: " << node.Version() << "\n";

    auto r = node.Echo(my_timer::EchoRequest{"hello from generated C++", 5});
    std::cout << "echo: echoed=" << r.echoed << " timerName=" << r.timerName
              << "\n";

    std::cout << "done.\n";
    return 0;
  } catch (const std::exception &e) {
    std::cerr << "error: " << e.what() << "\n";
    return 1;
  }
}
