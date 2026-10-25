#include "engine.hpp"
#include <cstring>

namespace gameinput::probe {
std::uint64_t qpc() noexcept { LARGE_INTEGER t{}; QueryPerformanceCounter(&t); return t.QuadPart; }
void add(volatile std::int64_t& value, std::int64_t n) noexcept {
    InterlockedExchangeAdd64(reinterpret_cast<volatile LONG64*>(&value), n);
}
static LONG read32(volatile std::int32_t& value) noexcept {
    return InterlockedCompareExchange(reinterpret_cast<volatile LONG*>(&value), 0, 0);
}
// SEH guards only post-success observations. Never probe pending/error pointers.
static bool readable(const void* pointer, std::size_t bytes) noexcept {
    MEMORY_BASIC_INFORMATION region{};
    if (!pointer || !VirtualQuery(pointer, &region, sizeof(region)) || region.State != MEM_COMMIT ||
        (region.Protect & (PAGE_GUARD | PAGE_NOACCESS)) ||
        !(region.Protect & (PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY))) return false;
    const auto offset = reinterpret_cast<std::uintptr_t>(pointer) - reinterpret_cast<std::uintptr_t>(region.BaseAddress);
    return offset <= region.RegionSize && bytes <= region.RegionSize - offset;
}
static bool copy_result(LPVOID output, LPDWORD returned, bool overlapped,
                        DWORD completed, std::array<std::uint8_t, packet_bytes>& bytes) noexcept {
    if (!readable(output, bytes.size()) || (!overlapped && !readable(returned, sizeof(*returned)))) return false;
    __try {
        if (!output || (!overlapped && (!returned || *returned != packet_bytes)) ||
            (overlapped && completed != packet_bytes)) return false;
        std::memcpy(bytes.data(), output, bytes.size());
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
static bool read_flag(LPVOID input, std::uint8_t& flag) noexcept {
    if (!readable(input,4)) return false;
    __try {
        flag = static_cast<const std::uint8_t*>(input)[3]; return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
void Engine::reset() noexcept {
    AcquireSRWLockExclusive(&state_lock_);
    policy_.clear(); ++close_epoch_;
    ReleaseSRWLockExclusive(&state_lock_);
}
bool Engine::initialize_timers() noexcept {
    if (waits_[0].timer) return true;
    for (auto& slot : waits_) {
        slot.timer = CreateWaitableTimerExW(nullptr, nullptr, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,
                                            TIMER_MODIFY_STATE | SYNCHRONIZE);
        if (!slot.timer) { destroy_timers(); return false; }
    }
    return true;
}
void Engine::destroy_timers() noexcept {
    for (auto& slot : waits_) if (slot.timer) { real_close(slot.timer); slot.timer = nullptr; }
}
bool Engine::expire_lease(std::uint64_t now) noexcept {
    const auto heartbeat = static_cast<std::uint64_t>(InterlockedCompareExchange64(
        reinterpret_cast<volatile LONG64*>(&shared->controller_heartbeat_qpc), 0, 0));
    const bool valid = heartbeat && heartbeat <= now && now - heartbeat <= frequency * 2;
    if (!valid) InterlockedCompareExchange(reinterpret_cast<volatile LONG*>(&shared->mode), 0, 1);
    return valid;
}
bool Engine::delay(std::uint64_t ticks, std::uint64_t& actual) noexcept {
    for (auto& slot : waits_) {
        if (!slot.timer || InterlockedCompareExchange(&slot.busy, 1, 0)) continue;
        LARGE_INTEGER due{};
        due.QuadPart = -static_cast<LONGLONG>((ticks * 10000000 + frequency - 1) / frequency);
        const auto before = qpc();
        bool waited = false;
        if (SetWaitableTimerEx(slot.timer, &due, 0, nullptr, nullptr, nullptr, 0)) {
            // The timer signal uses high resolution. Timeout is a failure guard;
            // Windows scheduling still offers no hard upper latency guarantee.
            const auto timeout_ms = static_cast<DWORD>((ticks * 1000 + frequency - 1) / frequency);
            const auto result = WaitForSingleObject(slot.timer, timeout_ms);
            waited = true; // any attempted wait counts as intentional throttling
            if (result != WAIT_OBJECT_0 && shared) add(shared->state_drops);
            actual = qpc() - before;
        }
        InterlockedExchange(&slot.busy, 0);
        return waited;
    }
    return false; // no available bounded timer: pass through
}
BOOL Engine::io(HANDLE h, DWORD code, LPVOID input, DWORD in_size, LPVOID output,
                DWORD out_size, LPDWORD returned, LPOVERLAPPED ov, std::uintptr_t callsite) noexcept {
    const DWORD incoming_error = GetLastError();
    if (!InterlockedCompareExchange(&enabled, 0, 0) || !shared || code != target_ioctl ||
        in_size != 4 || out_size != packet_bytes) {
        SetLastError(incoming_error);
        return real_io(h, code, input, in_size, output, out_size, returned, ov);
    }
    std::uint64_t epoch{};
    bool track = false;
    if (TryAcquireSRWLockExclusive(&state_lock_)) {
        epoch = close_epoch_; track = closes_inflight_ == 0;
        ReleaseSRWLockExclusive(&state_lock_);
    }
    Observation event{};
    event.begin = qpc(); event.handle = reinterpret_cast<std::uintptr_t>(h);
    event.callsite = callsite;
    event.tid = GetCurrentThreadId(); event.ioctl = code;
    SetLastError(incoming_error);
    event.result = real_io(h, code, input, in_size, output, out_size, returned, ov);
    event.error = GetLastError(); // capture before QPC/counters/completion/ETW/wait
    event.end = qpc(); event.latency = event.end - event.begin;
    add(shared->calls); add(shared->ioctl_qpc, event.latency);
    if (!event.result) {
        if (event.error == ERROR_IO_PENDING) add(shared->pending);
        else add(shared->errors);
        // Absolutely no inspection, completion query, or sleep on FALSE.
    } else {
        DWORD completed{};
        bool completion_valid = !ov;
        if (ov) {
            // lpBytesReturned is undefined for overlapped IO. TRUE is immediate,
            // but only the nonwaiting completion query can validate its length.
            __try { completion_valid = completion(h, ov, &completed, FALSE) != FALSE; }
            __except (EXCEPTION_EXECUTE_HANDLER) { completion_valid = false; }
        }
        std::array<std::uint8_t, packet_bytes> bytes{};
        if (completion_valid && copy_result(output, returned, ov != nullptr, completed, bytes)) {
            // Never touch caller input before the original API or on pending/
            // error paths. This is a post-success snapshot, not a guarantee of
            // the original submitted bytes if another thread mutates them.
            event.input_flag_valid = read_flag(input, event.input_flag3);
            event.observed = true; event.returned = packet_bytes;
            std::memcpy(&event.first_word, bytes.data(), sizeof(event.first_word));
            event.hash = packet_hash(bytes); add(shared->sync_success);
            Decision decision{};
            if (track && TryAcquireSRWLockExclusive(&state_lock_)) {
                if (epoch == close_epoch_ && closes_inflight_ == 0) {
                    const auto now = qpc();
                    const auto interval = read32(shared->interval_us);
                    auto mode = read32(shared->mode);
                    if (mode == static_cast<LONG>(abi::Mode::Mitigate) && !expire_lease(now)) mode = 0;
                    decision = policy_.observe(event.handle, bytes, now,
                        valid_interval(interval) ? frequency * interval / 1000000 : 0,
                        mode == 1 && valid_interval(interval) && event.input_flag_valid);
                }
                ReleaseSRWLockExclusive(&state_lock_);
            }
            if (!decision.tracked) add(shared->state_drops);
            if (decision.unchanged) add(shared->unchanged);
            event.streak = decision.streak;
            if (decision.delay && InterlockedCompareExchange(&enabled, 0, 0)) {
                if (delay(decision.delay, event.delay)) {
                    add(shared->throttled); add(shared->delay_qpc, event.delay);
                } else add(shared->state_drops);
            }
        } else add(shared->unobserved);
    }
    if (emit) emit(event);
    SetLastError(event.error);
    return event.result;
}
BOOL Engine::close(HANDLE h) noexcept {
    const auto incoming_error = GetLastError();
    if (!InterlockedCompareExchange(&enabled, 0, 0)) {
        SetLastError(incoming_error); return real_close(h);
    }
    AcquireSRWLockExclusive(&state_lock_);
    ++close_epoch_; ++closes_inflight_;
    ReleaseSRWLockExclusive(&state_lock_);
    SetLastError(incoming_error);
    const auto result = real_close(h);
    const auto error = GetLastError();
    AcquireSRWLockExclusive(&state_lock_);
    if (result) policy_.close(reinterpret_cast<std::uintptr_t>(h));
    ++close_epoch_; --closes_inflight_;
    ReleaseSRWLockExclusive(&state_lock_);
    if (result && shared) add(shared->closes);
    SetLastError(error); return result;
}
}
