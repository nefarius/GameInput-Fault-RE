#include "probe/engine.hpp"
#include "probe/mapping.hpp"
#include <detours.h>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <thread>
#include <vector>
#include <algorithm>
#include <sddl.h>
#define CHECK(x) do { if (!(x)) { std::cerr << __LINE__ << ": " #x " last_error=" << GetLastError() << "\n"; std::exit(1); } } while (0)
using namespace gameinput::probe;
namespace {
enum class Behavior { Good, Error, Pending, Short, Unreadable, CompletionError };
std::atomic<Behavior> behavior{Behavior::Good};
std::atomic<DWORD> completion_queries{};
std::atomic<unsigned> calls{};
std::atomic<bool> close_success{true};
std::atomic<DWORD> incoming{};
std::array<std::uint8_t, packet_bytes> payload{};
Engine engine;
__declspec(noinline) BOOL WINAPI synthetic(HANDLE, DWORD, LPVOID, DWORD, LPVOID output,
                                        DWORD, LPDWORD returned, LPOVERLAPPED ov) {
    incoming = GetLastError(); ++calls;
    const auto b = behavior.load();
    if (b == Behavior::Error || b == Behavior::Pending) {
        SetLastError(b == Behavior::Pending ? ERROR_IO_PENDING : ERROR_ACCESS_DENIED); return FALSE;
    }
    if (b != Behavior::Unreadable) {
        if (output) std::memcpy(output, payload.data(), payload.size());
        if (returned && !ov) *returned = b == Behavior::Short ? 23 : 24;
    }
    SetLastError(0x1234); return TRUE;
}
BOOL WINAPI complete(HANDLE, LPOVERLAPPED, LPDWORD returned, BOOL wait) {
    ++completion_queries; CHECK(wait == FALSE);
    *returned = behavior == Behavior::Short ? 23 : 24;
    SetLastError(0x9999);
    return behavior == Behavior::CompletionError ? FALSE : TRUE;
}
BOOL WINAPI close_fake(HANDLE) { SetLastError(0x5678); return close_success ? TRUE : FALSE; }
BOOL WINAPI hook(HANDLE h, DWORD code, LPVOID in, DWORD n, LPVOID out, DWORD m, LPDWORD bytes, LPOVERLAPPED ov) {
    return engine.io(h, code, in, n, out, m, bytes, ov);
}
IoFunction target = synthetic;
std::uint64_t invoke(HANDLE handle, DWORD code = target_ioctl, DWORD in_size = 4,
                     DWORD out_size = 24, LPOVERLAPPED ov = nullptr) {
    DWORD input = 0x01000000, returned = 0xdeadbeef;
    std::array<std::uint8_t, packet_bytes> output{}; output.fill(0xab);
    const auto before = qpc();
    SetLastError(0x4321);
    const auto result = synthetic(handle, code, &input, in_size, output.data(), out_size, &returned, ov);
    const auto error = GetLastError(); const auto elapsed = qpc() - before;
    CHECK(incoming == 0x4321);
    if (behavior == Behavior::Pending || behavior == Behavior::Error) {
        CHECK(result == FALSE);
        CHECK(error == (behavior == Behavior::Pending ? ERROR_IO_PENDING : ERROR_ACCESS_DENIED));
        CHECK(returned == 0xdeadbeef); CHECK(output[0] == 0xab && output[23] == 0xab);
    } else {
        CHECK(result == TRUE && error == 0x1234);
        CHECK(output == payload);
        CHECK(returned == (ov ? 0xdeadbeef : (behavior == Behavior::Short ? 23 : 24)));
    }
    return elapsed;
}
}
int main(int argc, char** argv) {
    CHECK(argc == 2);
    HANDLE section = CreateFileMappingW(INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE, 0, sizeof(abi::Shared), nullptr);
    CHECK(section);
    using QuerySection = LONG (NTAPI*)(HANDLE, int, void*, ULONG, ULONG*);
    struct SectionBasic { void* base; ULONG attributes; LARGE_INTEGER size; };
    auto query = reinterpret_cast<QuerySection>(GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtQuerySection"));
    SectionBasic basic{}; CHECK(query && query(section, 0, &basic, sizeof(basic), nullptr) >= 0);
    std::cout << "mapping logical_bytes=" << sizeof(abi::Shared) << " native_section_bytes=" << basic.size.QuadPart << "\n";
    CHECK(validate_mapping(section) != ERROR_SUCCESS); // unnamed/unprotected refused
    CHECK(CloseHandle(section));
    for (const auto* dacl : {abi::security_sddl, L"D:P(A;;GA;;;WD)", L"D:(A;;GA;;;SY)(A;;GA;;;BA)"}) {
        PSECURITY_DESCRIPTOR descriptor{};
        CHECK(ConvertStringSecurityDescriptorToSecurityDescriptorW(dacl, SDDL_REVISION_1, &descriptor, nullptr));
        SECURITY_ATTRIBUTES security{sizeof(security), descriptor, FALSE};
        section = CreateFileMappingW(INVALID_HANDLE_VALUE, &security, PAGE_READWRITE, 0, sizeof(abi::Shared), nullptr);
        LocalFree(descriptor); CHECK(section);
        CHECK((validate_mapping_security(section) == ERROR_SUCCESS) == (dacl == abi::security_sddl));
        CHECK(CloseHandle(section));
    }
    // Loading alone has no effects; production Start rejects this test image.
    HMODULE dll = LoadLibraryA(argv[1]); CHECK(dll);
    using Export = DWORD (WINAPI*)(void*);
    auto start = reinterpret_cast<Export>(GetProcAddress(dll, "ProbeStart"));
    auto stop = reinterpret_cast<Export>(GetProcAddress(dll, "ProbeStop"));
    CHECK(start && stop); CHECK(start(nullptr) == ERROR_ACCESS_DENIED);
    // Even an unrelated image consumes the transferred handle on failure.
    HANDLE consumed = CreateEventW(nullptr, FALSE, FALSE, nullptr); CHECK(consumed);
    CHECK(start(consumed) == ERROR_ACCESS_DENIED);
    DWORD flags{}; CHECK(!GetHandleInformation(consumed, &flags) && GetLastError() == ERROR_INVALID_HANDLE);
    CHECK(stop(nullptr) == ERROR_SUCCESS); CHECK(FreeLibrary(dll));
    abi::Shared shared{};
    LARGE_INTEGER frequency{}; QueryPerformanceFrequency(&frequency);
    engine.shared = &shared; engine.frequency = frequency.QuadPart;
    engine.real_io = target; engine.real_close = close_fake; engine.completion = complete; engine.enabled = 1;
    shared.interval_us = 8000;
    CHECK(engine.initialize_timers());
    CHECK(DetourTransactionBegin() == NO_ERROR);
    CHECK(DetourUpdateThread(GetCurrentThread()) == NO_ERROR);
    CHECK(DetourAttach(reinterpret_cast<PVOID*>(&target), hook) == NO_ERROR);
    CHECK(DetourTransactionCommit() == NO_ERROR);
    engine.real_io = target; // actual trampoline, synthetic calls go through detour
    HANDLE h = reinterpret_cast<HANDLE>(0x1230);
    invoke(h); invoke(h);
    CHECK(shared.calls == 2 && shared.sync_success == 2 && shared.unchanged == 1 && !shared.throttled);
    shared.mode = 1; shared.controller_heartbeat_qpc = qpc();
    auto elapsed = invoke(h);
    CHECK(elapsed >= engine.frequency * 6 / 1000); // Windows scheduling tolerance
    CHECK(shared.throttled == 1);
    std::cout << "unchanged 8ms actual_ms=" << elapsed * 1000.0 / engine.frequency << "\n";
    auto before_throttled = shared.throttled;
    payload[23] = 1; invoke(h); CHECK(shared.throttled == before_throttled);
    OVERLAPPED ov{};
    payload[22] = 2; invoke(h, target_ioctl, 4, 24, &ov);
    CHECK(completion_queries == 1);
    invoke(h, target_ioctl, 4, 24, &ov); CHECK(shared.throttled == before_throttled + 1);
    before_throttled = shared.throttled;
    behavior = Behavior::Pending; invoke(h, target_ioctl, 4, 24, &ov);
    CHECK(shared.pending == 1 && completion_queries == 2 && shared.throttled == before_throttled);
    // Poison pending pointers, including lpBytesReturned and OVERLAPPED: no reads.
    SetLastError(77);
    CHECK(!synthetic(h, target_ioctl, nullptr, 4, reinterpret_cast<void*>(1), 24,
                     reinterpret_cast<DWORD*>(1), reinterpret_cast<OVERLAPPED*>(1)));
    CHECK(GetLastError() == ERROR_IO_PENDING && completion_queries == 2);
    // A probe must not consume a caller's guard exception before the real API,
    // nor inspect guarded input after an otherwise successful call.
    void* guarded=VirtualAlloc(nullptr,4096,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);
    CHECK(guarded);
    DWORD old_protection{};
    CHECK(VirtualProtect(guarded,4096,PAGE_READWRITE|PAGE_GUARD,&old_protection));
    DWORD guard_bytes{};std::array<std::uint8_t,24> guard_output{};
    CHECK(!synthetic(h,target_ioctl,guarded,4,guard_output.data(),24,&guard_bytes,&ov));
    CHECK(GetLastError()==ERROR_IO_PENDING);
    MEMORY_BASIC_INFORMATION guard_info{};
    CHECK(VirtualQuery(guarded,&guard_info,sizeof(guard_info)) && (guard_info.Protect&PAGE_GUARD));
    behavior=Behavior::Good;
    CHECK(synthetic(h,target_ioctl,guarded,4,guard_output.data(),24,&guard_bytes,nullptr));
    CHECK(GetLastError()==0x1234);
    CHECK(VirtualQuery(guarded,&guard_info,sizeof(guard_info)) && (guard_info.Protect&PAGE_GUARD));
    CHECK(VirtualFree(guarded,0,MEM_RELEASE));
    behavior = Behavior::Error; invoke(h); CHECK(shared.errors == 1);
    behavior = Behavior::Short; invoke(h); invoke(h, target_ioctl, 4, 24, &ov);
    behavior = Behavior::CompletionError; invoke(h, target_ioctl, 4, 24, &ov);
    CHECK(shared.unobserved == 3 && shared.throttled == before_throttled);
    behavior = Behavior::Unreadable;
    DWORD unreadable_bytes = 24, readable_input{};
    CHECK(synthetic(h, target_ioctl, &readable_input, 4, reinterpret_cast<void*>(1), 24, &unreadable_bytes, nullptr));
    CHECK(GetLastError() == 0x1234 && shared.unobserved == 4 && shared.throttled == before_throttled);
    behavior = Behavior::Good;
    invoke(h, 0x123); invoke(h, target_ioctl, 3); invoke(h, target_ioctl, 4, 23);
    CHECK(shared.throttled == before_throttled);
    close_success = false; CHECK(!engine.close(h)); CHECK(GetLastError() == 0x5678);
    close_success = true;
    CHECK(engine.close(h)); CHECK(GetLastError() == 0x5678);
    invoke(h); CHECK(shared.throttled == before_throttled); // handle reuse clears cache
    shared.interval_us = 8001; invoke(h); CHECK(shared.throttled == before_throttled);
    shared.interval_us = 8000; shared.controller_heartbeat_qpc = qpc() - engine.frequency * 3;
    invoke(h); CHECK(shared.mode == 0 && shared.throttled == before_throttled);
    shared.mode = 1; shared.controller_heartbeat_qpc = qpc() + engine.frequency;
    invoke(h); CHECK(shared.mode == 0);
    // Real OS API error path, caller last-error preserved through instrumentation.
    engine.real_io = ::DeviceIoControl;
    DWORD input{}, returned{}; std::array<std::uint8_t, 24> out{};
    SetLastError(123);
    CHECK(!engine.io(INVALID_HANDLE_VALUE, target_ioctl, &input, 4, out.data(), 24, &returned, nullptr));
    CHECK(GetLastError() == ERROR_INVALID_HANDLE);
    engine.real_io = target;
    // Concurrent observations and close/reuse use bounded synchronized state.
    std::vector<std::thread> workers;
    for (int i = 0; i < 8; ++i) workers.emplace_back([i] {
        DWORD in{}, bytes{}; std::array<std::uint8_t, 24> out{};
        HANDLE local = reinterpret_cast<HANDLE>(static_cast<std::uintptr_t>(0x4000 + i * 4));
        for (int j = 0; j < 500; ++j) {
            engine.io(local, target_ioctl, &in, 4, out.data(), 24, &bytes, nullptr);
            if (j % 4 == 0) engine.close(local);
        }
    });
    for (auto& worker : workers) worker.join();
    CHECK(shared.calls > 4000 && shared.closes == 1001);
    // Measure nominal 1ms and 8ms delay distribution without a brittle scheduler
    // deadline assertion. Output is evidence of test-host scheduling, not hardware.
    for (const int us : {1000, 8000}) {
        std::vector<double> times;
        shared.interval_us = us; shared.mode = 1; shared.controller_heartbeat_qpc = qpc();
        engine.reset(); invoke(h);
        for (int i = 0; i < 16; ++i) times.push_back(invoke(h) * 1000.0 / engine.frequency);
        std::sort(times.begin(), times.end());
        std::cout << "nominal_us=" << us << " actual_ms min=" << times.front()
                  << " median=" << times[times.size()/2] << " max=" << times.back()
                  << " overshoot_ms=" << (times.back() - us/1000.0) << "\n";
    }
    shared.interval_us = 8000;
    std::uint64_t rates[2]{};
    for (int mode = 0; mode < 2; ++mode) {
        shared.mode = mode; shared.controller_heartbeat_qpc = qpc(); engine.reset();
        const auto begin = qpc(); const auto stop_at = begin + engine.frequency/4;
        std::uint64_t count{};
        do { invoke(h); ++count; } while (qpc() < stop_at);
        rates[mode] = count * engine.frequency / (qpc() - begin);
    }
    CHECK(rates[0] > rates[1]);
    std::cout << "synthetic flood ONLY: observe_hz=" << rates[0] << " mitigate_hz=" << rates[1]
              << " reduction_percent=" << 100.0 * (1.0 - double(rates[1])/rates[0]) << "\n";
    CHECK(DetourTransactionBegin() == NO_ERROR);
    CHECK(DetourUpdateThread(GetCurrentThread()) == NO_ERROR);
    CHECK(DetourDetach(reinterpret_cast<PVOID*>(&target), hook) == NO_ERROR);
    CHECK(DetourTransactionCommit() == NO_ERROR);
    // Disabled path and explicit restart: original callable after detach, then
    // reset state and reattach safely with no outstanding worker threads.
    const auto final_count = shared.calls;
    engine.enabled = 0;
    invoke(h); CHECK(shared.calls == final_count);
    engine.real_io = target; engine.reset();
    CHECK(DetourTransactionBegin() == NO_ERROR);
    CHECK(DetourUpdateThread(GetCurrentThread()) == NO_ERROR);
    CHECK(DetourAttach(reinterpret_cast<PVOID*>(&target), hook) == NO_ERROR);
    CHECK(DetourTransactionCommit() == NO_ERROR);
    engine.real_io = target; engine.enabled = 1; shared.mode = 0;
    invoke(h); CHECK(shared.calls == final_count + 1);
    CHECK(DetourTransactionBegin() == NO_ERROR);
    CHECK(DetourUpdateThread(GetCurrentThread()) == NO_ERROR);
    CHECK(DetourDetach(reinterpret_cast<PVOID*>(&target), hook) == NO_ERROR);
    CHECK(DetourTransactionCommit() == NO_ERROR);
    engine.real_close = ::CloseHandle; engine.destroy_timers();
    std::cout << "Windows integration: real Detours, immediate overlapped, pending poison pointers, error, close/reuse, intervals, lease, concurrency passed\n";
}
