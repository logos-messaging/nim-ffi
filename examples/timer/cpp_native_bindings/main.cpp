// Driver for the GENERATED native C++ bindings (my_timer.hpp).
#include "my_timer.hpp"
#include <iostream>
int main() {
  try {
    my_timer::My_timerNode node(my_timer::TimerConfig{"cpp-native-gen"});
    std::cout << "version: " << node.Version() << "\n";

    my_timer::EchoEvent gotEvt;
    bool got = false;
    node.OnEchoFired([&](const my_timer::EchoEvent& e){ gotEvt = e; got = true; });

    auto r = node.Echo(my_timer::EchoRequest{"hello from generated C++", 5});
    std::cout << "echo: echoed=" << r.echoed << " timerName=" << r.timerName << "\n";
    if (got) std::cout << "event OnEchoFired: message=\"" << gotEvt.message << "\" echoCount=" << gotEvt.echoCount << "\n";

    // seq + Option params (ComplexRequest), typed ComplexResponse return.
    my_timer::ComplexRequest creq;
    creq.messages = {{"one", 0}, {"two", 0}};
    creq.tags = {"a", "b"};
    creq.note = "a note";
    creq.retries = 3;
    auto c = node.Complex(creq);
    std::cout << "complex: itemCount=" << c.itemCount << " hasNote=" << c.hasNote
              << " summary=\"" << c.summary << "\"\n";

    // Multiple struct params (JobSpec, RetryPolicy, ScheduleConfig).
    my_timer::JobSpec job; job.name = "nightly"; job.payload = {"x"}; job.priority = 5;
    my_timer::RetryPolicy retry; retry.maxAttempts = 3; retry.backoffMs = 100; retry.retryOn = {"timeout"};
    my_timer::ScheduleConfig sched; sched.startAtMs = 1000; sched.intervalMs = 5000; sched.jitter = 50;
    auto s = node.Schedule(job, retry, sched);
    std::cout << "schedule: jobId=\"" << s.jobId << "\" willRunCount=" << s.willRunCount << "\n";

    std::cout << "done.\n";
    return 0;
  } catch (const std::exception &e) {
    std::cerr << "error: " << e.what() << "\n"; return 1;
  }
}
