#pragma once
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <Windows.h>
#include "policy.hpp"
#include "protocol.hpp"

namespace gameinput::probe {
using IoFunction = decltype(&::DeviceIoControl);
using CloseFunction = decltype(&::CloseHandle);
using CompletionFunction = decltype(&::GetOverlappedResult);
struct Observation {
    std::uint64_t begin, end, handle, latency, delay, hash, streak, callsite;
    DWORD tid, ioctl, error, first_word, returned;
    std::uint8_t input_flag3;
    bool input_flag_valid;
    BOOL result;
    bool observed;
};
using EmitFunction = void (*)(const Observation&) noexcept;
class Engine {
    SRWLOCK state_lock_ = SRWLOCK_INIT;
    Policy policy_;
    std::uint64_t close_epoch_{};
    std::uint32_t closes_inflight_{};
    struct WaitSlot { HANDLE timer{}; volatile LONG busy{}; };
    std::array<WaitSlot, 64> waits_{};
public:
    abi::Shared* shared{};
    IoFunction real_io = ::DeviceIoControl;
    CloseFunction real_close = ::CloseHandle;
    CompletionFunction completion = ::GetOverlappedResult;
    EmitFunction emit{};
    std::uint64_t frequency{};
    volatile LONG enabled{};
    BOOL io(HANDLE h, DWORD code, LPVOID input, DWORD in_size, LPVOID output,
            DWORD out_size, LPDWORD returned, LPOVERLAPPED ov, std::uintptr_t callsite = 0) noexcept;
    BOOL close(HANDLE h) noexcept;
    void reset() noexcept;
    // Setup/quiescent teardown only. No timer allocation on the hook path.
    bool initialize_timers() noexcept;
    void destroy_timers() noexcept;
    bool expire_lease(std::uint64_t now) noexcept;
    bool delay(std::uint64_t ticks, std::uint64_t& actual) noexcept;
};
std::uint64_t qpc() noexcept;
void add(volatile std::int64_t& counter, std::int64_t n = 1) noexcept;
}
