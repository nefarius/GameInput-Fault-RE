#include "probe/policy.hpp"
#include <cstdlib>
#include <iostream>
#define CHECK(x) do { if (!(x)) { std::cerr << __LINE__ << ": " #x "\n"; std::exit(1); } } while (0)
using namespace gameinput::probe;
int main() {
    Policy p;
    std::array<std::uint8_t, packet_bytes> b{};
    CHECK(!p.observe(1, b, 100, 8000, true).unchanged);
    auto d = p.observe(1, b, 100, 8000, true);
    CHECK(d.unchanged && d.delay == 8000 && d.streak == 1);
    d = p.observe(1, b, 100, 8000, true);
    CHECK(d.delay <= 8000); // concurrent completions never reserve >one interval
    b[23] = 1; // same first word, changed last byte MUST pass immediately
    d = p.observe(1, b, 100, 8000, true);
    CHECK(!d.unchanged && !d.delay);
    CHECK(p.observe(1, b, 8100, 8000, true).delay == 0);
    CHECK(p.observe(1, b, 8100, 8000, false).delay == 0);
    CHECK(!p.observe(2, b, 8100, 8000, true).unchanged);
    p.close(1);
    CHECK(!p.observe(1, b, 8100, 8000, true).unchanged);
    p.clear();
    for (std::uintptr_t i = 0; i < state_capacity; ++i) CHECK(p.observe(i, b, 0, 8000, true).tracked);
    CHECK(!p.observe(99999, b, 0, 8000, true).tracked);
    p.close(4); CHECK(p.observe(99999, b, 0, 8000, true).tracked);
    CHECK(valid_interval(1000) && valid_interval(8000));
    CHECK(!valid_interval(999) && !valid_interval(8001) && !valid_interval(-1));
    std::cout << "portable policy: whole-buffer comparison, cadence, close/reuse, saturation, interval bounds passed\n";
}
