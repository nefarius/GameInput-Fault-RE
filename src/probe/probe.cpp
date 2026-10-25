#include "engine.hpp"
#include "identity.hpp"
#include "mapping.hpp"
#include <detours.h>
#include <TlHelp32.h>
#include <sddl.h>
#include <TraceLoggingProvider.h>
#include <array>
#include <intrin.h>
#include "build_identity.hpp"

extern "C" __declspec(dllexport) extern const char ProbeBuildId[] = GAMEINPUT_BUILD_ID;

TRACELOGGING_DEFINE_PROVIDER(g_provider, "GameInputProbe",
    (0xb91b050b, 0x64b5, 0x4e3b, 0x9a, 0x2f, 0x42, 0x04, 0x6d, 0x48, 0xe9, 0xce));
namespace {
using namespace gameinput::probe;
SRWLOCK lifecycle_lock = SRWLOCK_INIT;
SRWLOCK hook_gate = SRWLOCK_INIT;
Engine engine;
HANDLE mapping{};
bool attached{};
bool registered{};
HMODULE retained{};
PTP_TIMER housekeeping{};
void sample() noexcept;
void CALLBACK on_housekeeping(PTP_CALLBACK_INSTANCE, void*, PTP_TIMER) noexcept {
    sample();
    if (engine.shared) engine.expire_lease(qpc());
}

void emit(const Observation& e) noexcept {
    TraceLoggingWrite(g_provider, "Ioctl",
        TraceLoggingUInt32(GetCurrentProcessId(), "pid"), TraceLoggingUInt32(e.tid, "tid"),
        TraceLoggingUInt64(e.begin, "begin_qpc"), TraceLoggingUInt64(e.end, "end_qpc"),
        TraceLoggingUInt64(e.handle, "handle"), TraceLoggingUInt32(e.ioctl, "ioctl"),
        TraceLoggingUInt64(e.callsite, "callsite_va"),
        TraceLoggingUInt64(e.latency, "latency_qpc"), TraceLoggingBool(e.result != FALSE, "result"),
        TraceLoggingUInt32(e.error, "last_error"), TraceLoggingBool(e.observed, "observed"),
        TraceLoggingUInt32(e.returned, "completed_bytes"), TraceLoggingUInt32(e.first_word, "first_word"),
        TraceLoggingUInt8(e.input_flag3, "input_flag3"), TraceLoggingBool(e.input_flag_valid, "input_flag_valid"),
        TraceLoggingUInt64(e.hash, "buffer_hash"), TraceLoggingUInt64(e.streak, "unchanged_streak"),
        TraceLoggingUInt64(e.delay, "delay_qpc"));
}
BOOL WINAPI io_hook(HANDLE h, DWORD code, LPVOID input, DWORD in_size, LPVOID output,
                    DWORD out_size, LPDWORD returned, LPOVERLAPPED ov) {
    const auto incoming = GetLastError();
    AcquireSRWLockShared(&hook_gate);
    SetLastError(incoming);
    const auto result = engine.io(h, code, input, in_size, output, out_size, returned, ov,
                                   reinterpret_cast<std::uintptr_t>(_ReturnAddress()));
    const auto error = GetLastError();
    ReleaseSRWLockShared(&hook_gate);
    SetLastError(error); return result;
}
BOOL WINAPI close_hook(HANDLE handle) {
    const auto incoming = GetLastError();
    AcquireSRWLockShared(&hook_gate);
    SetLastError(incoming);
    const auto result = engine.close(handle);
    const auto error = GetLastError();
    ReleaseSRWLockShared(&hook_gate);
    SetLastError(error); return result;
}
// Snapshot and open every existing process thread BEFORE beginning suspension.
// Fixed bound; inaccessible/overflow/racing thread inventory fails the operation.
// The retained DLL keeps threads already inside hook stubs safe after detachment.
DWORD transact(bool attach) noexcept {
    std::array<HANDLE, 4096> threads{};
    size_t count{};
    const auto snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return GetLastError();
    THREADENTRY32 entry{}; entry.dwSize = sizeof(entry);
    DWORD error = ERROR_SUCCESS;
    if (!Thread32First(snapshot, &entry)) error = GetLastError();
    else do {
        if (entry.th32OwnerProcessID != GetCurrentProcessId() || entry.th32ThreadID == GetCurrentThreadId()) continue;
        if (count == threads.size()) { error = ERROR_TOO_MANY_TCBS; break; }
        HANDLE thread = OpenThread(SYNCHRONIZE | THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_SET_CONTEXT | THREAD_QUERY_INFORMATION,
                                   FALSE, entry.th32ThreadID);
        if (!thread) { error = GetLastError(); break; }
        threads[count++] = thread;
    } while (Thread32Next(snapshot, &entry));
    if (error == ERROR_SUCCESS && GetLastError() != ERROR_NO_MORE_FILES) error = GetLastError();
    engine.real_close(snapshot);
    if (error == ERROR_SUCCESS) {
        error = DetourTransactionBegin();
        if (error == NO_ERROR) {
            // Prepare decoding, trampolines and patch operations before any
            // thread is suspended. The pinned Detours build uses VirtualAlloc
            // for its transaction records, including UpdateThread and cleanup.
            error = attach ? DetourAttach(reinterpret_cast<PVOID*>(&engine.real_io), io_hook)
                           : DetourDetach(reinterpret_cast<PVOID*>(&engine.real_io), io_hook);
            if (error == NO_ERROR) error = attach ? DetourAttach(reinterpret_cast<PVOID*>(&engine.real_close), close_hook)
                                                 : DetourDetach(reinterpret_cast<PVOID*>(&engine.real_close), close_hook);
            if (error == NO_ERROR) error = DetourUpdateThread(GetCurrentThread());
            for (size_t i = 0; i < count && error == NO_ERROR; ++i) {
                // Exited threads have no instruction pointer to relocate.
                if (WaitForSingleObject(threads[i], 0) == WAIT_OBJECT_0) continue;
                error = DetourUpdateThread(threads[i]);
            }
            if (error == NO_ERROR) error = DetourTransactionCommit();
            else DetourTransactionAbort();
        }
    }
    for (size_t i = 0; i < count; ++i) engine.real_close(threads[i]);
    return error;
}
void sample() noexcept {
    FILETIME created{}, exited{}, kernel{}, user{};
    if (!engine.shared) return;
    if (GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user)) {
        ULARGE_INTEGER k{}, u{};
        k.LowPart = kernel.dwLowDateTime; k.HighPart = kernel.dwHighDateTime;
        u.LowPart = user.dwLowDateTime; u.HighPart = user.dwHighDateTime;
        InterlockedExchange64(reinterpret_cast<volatile LONG64*>(&engine.shared->process_cpu_100ns), k.QuadPart + u.QuadPart);
    }
    InterlockedExchange64(reinterpret_cast<volatile LONG64*>(&engine.shared->sample_qpc), qpc());
}
void close_argument(HANDLE handle) noexcept {
    __try { if (handle) CloseHandle(handle); }
    __except (EXCEPTION_EXECUTE_HANDLER) { }
}
DWORD prepare_mapping(HANDLE transferred, const abi::Shared& identity) noexcept {
    HANDLE section = transferred;
    if (!section) {
        PSECURITY_DESCRIPTOR security{};
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(abi::security_sddl, SDDL_REVISION_1, &security, nullptr))
            return GetLastError();
        SECURITY_ATTRIBUTES sa{sizeof(sa), security, FALSE};
        wchar_t name[100]{};
        swprintf_s(name, L"%s%lu", abi::mapping_prefix, GetCurrentProcessId());
        section = CreateFileMappingW(INVALID_HANDLE_VALUE, &sa, PAGE_READWRITE, 0, sizeof(abi::Shared), name);
        const auto error = GetLastError();
        LocalFree(security);
        if (!section) return error;
        if (error == ERROR_ALREADY_EXISTS) { close_argument(section); return ERROR_DUP_NAME; }
    }
    DWORD error = validate_mapping(section);
    abi::Shared* view = nullptr;
    if (!error) {
        view = static_cast<abi::Shared*>(MapViewOfFile(section, FILE_MAP_READ | FILE_MAP_WRITE, 0, 0, sizeof(abi::Shared)));
        if (!view) error = GetLastError();
        else {
            const auto* bytes = reinterpret_cast<const std::uint8_t*>(view);
            for (size_t i = 0; i < sizeof(*view); ++i) if (bytes[i]) { error = ERROR_INVALID_DATA; break; }
        }
    }
    if (error) { if (view) UnmapViewOfFile(view); close_argument(section); return error; }
    mapping = section; engine.shared = view;
    *engine.shared = identity;
    engine.shared->magic_value = abi::magic; engine.shared->abi_version = abi::version;
    engine.shared->struct_bytes = sizeof(abi::Shared); engine.shared->pid = GetCurrentProcessId();
    engine.shared->interval_us = 8000;
    LARGE_INTEGER frequency{}; QueryPerformanceFrequency(&frequency); engine.frequency = frequency.QuadPart;
    engine.shared->qpc_frequency = engine.frequency; engine.shared->start_qpc = qpc();
    sample(); engine.shared->start_cpu_100ns = engine.shared->process_cpu_100ns;
    return ERROR_SUCCESS;
}
}
extern "C" __declspec(dllexport) DWORD WINAPI ProbeSample(void* reserved) {
    if (reserved) return ERROR_INVALID_PARAMETER;
    AcquireSRWLockShared(&lifecycle_lock);
    const auto result = engine.shared ? ERROR_SUCCESS : ERROR_NOT_READY;
    sample(); ReleaseSRWLockShared(&lifecycle_lock); return result;
}
extern "C" __declspec(dllexport) DWORD WINAPI ProbeStart(void* transferred) {
    if (!TryAcquireSRWLockExclusive(&lifecycle_lock)) { close_argument(transferred); return ERROR_BUSY; }
    DWORD error = ERROR_SUCCESS;
    if (attached) { close_argument(transferred); ReleaseSRWLockExclusive(&lifecycle_lock); return ERROR_ALREADY_EXISTS; }
    if (!engine.shared) {
        abi::Shared identity{};
        error = identify(identity);
        if (error == ERROR_SUCCESS) error = prepare_mapping(transferred, identity);
        else close_argument(transferred);
    } else close_argument(transferred);
    if (!error && !retained) {
        // Permanent pin deliberately makes Eject/FreeLibrary incapable of unsafe
        // unload. Even a thread paused before entering a hook remains safe.
        if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
                               reinterpret_cast<LPCWSTR>(&ProbeStart), &retained)) error = GetLastError();
    }
    if (!error) {
        if (!registered) { registered = TraceLoggingRegister(g_provider) == ERROR_SUCCESS; }
        engine.emit = emit; engine.reset(); engine.initialize_timers();
        if (!housekeeping) housekeeping = CreateThreadpoolTimer(on_housekeeping, nullptr, nullptr);
        if (!housekeeping) error = GetLastError();
        InterlockedExchange(reinterpret_cast<volatile LONG*>(&engine.shared->mode), 0);
        if (!error) {
            AcquireSRWLockExclusive(&hook_gate);
            error = transact(true);
            if (!error) { attached = true; InterlockedExchange(&engine.enabled, 1); }
            ReleaseSRWLockExclusive(&hook_gate);
            if (!error) {
                LARGE_INTEGER relative{}; relative.QuadPart = -2500000;
                FILETIME due{relative.LowPart, static_cast<DWORD>(relative.HighPart)};
                SetThreadpoolTimer(housekeeping, &due, 250, 0);
            }
        }
        InterlockedExchange(reinterpret_cast<volatile LONG*>(&engine.shared->status), error ? 2 : 1);
    }
    ReleaseSRWLockExclusive(&lifecycle_lock); return error;
}
extern "C" __declspec(dllexport) DWORD WINAPI ProbeStop(void* reserved) {
    if (reserved) return ERROR_INVALID_PARAMETER;
    if (!TryAcquireSRWLockExclusive(&lifecycle_lock)) return ERROR_BUSY;
    InterlockedExchange(&engine.enabled, 0);
    if (housekeeping) { SetThreadpoolTimer(housekeeping, nullptr, 0, 0); WaitForThreadpoolTimerCallbacks(housekeeping, TRUE); }
    if (engine.shared) InterlockedExchange(reinterpret_cast<volatile LONG*>(&engine.shared->mode), 0);
    DWORD error = ERROR_SUCCESS;
    if (attached) {
        const auto deadline = GetTickCount64() + 2000;
        bool exclusive = false;
        do { exclusive = TryAcquireSRWLockExclusive(&hook_gate) != FALSE; if (!exclusive) Sleep(1); }
        while (!exclusive && GetTickCount64() < deadline);
        if (!exclusive) error = ERROR_BUSY;
        else {
            error = transact(false);
            if (!error) attached = false;
            ReleaseSRWLockExclusive(&hook_gate);
        }
    }
    if (engine.shared) InterlockedExchange(reinterpret_cast<volatile LONG*>(&engine.shared->status), error ? 3 : 2);
    sample(); ReleaseSRWLockExclusive(&lifecycle_lock); return error;
}
// Loader callbacks do no hooking, waiting, thread creation, allocation, or teardown.
BOOL WINAPI DllMain(HINSTANCE, DWORD, LPVOID) { return TRUE; }
