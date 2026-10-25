#pragma once
#include <cstddef>
#include <cstdint>

// Wire ABI v1, x64 Windows, little endian, natural alignment (no packing).
// Mapping: Global\GameInputProbe-v1-<decimal PID>, protected for SYSTEM and
// Administrators. Controller normally creates it; see transferred-handle startup.
// Wrapper calls DWORD WINAPI ProbeStart(void* mapping_handle) after LoadLibrary.
// Elevated controller creates the Global mapping with the exact protected DACL
// above, fresh and zeroed, then DuplicateHandle into target (same access, including
// SECTION_QUERY, READ_CONTROL, SECTION_MAP_READ/WRITE). Pass that target handle
// as the argument. Probe validates name, page-rounded section size, protected DACL and
// zero initial contents. Start consumes the duplicated handle on ALL paths:
// success retains it; failure/already-started closes it. Keep controller mapping
// alive through remote call. On timeout never force-close the target handle.
// nullptr still permits privileged targets to create the secure mapping locally.
// ProbeStop and ProbeSample accept only nullptr.
// All three exports return Win32 error codes. Never call under loader lock.
// A successful start PINs this DLL until process exit, including after stop:
// FreeLibrary/eject MUST NOT be used as an unloading mechanism. Stop detaches
// outside loader lock; ERROR_BUSY means disabled but still attached: retry.
// Mapping remains valid after stop, so wrappers can inspect the final counters.
// All concurrently accessed scalars use aligned Interlocked operations. Readers
// take independent atomic snapshots (the counters are NOT one coherent sample).
// Wrapper writes ONLY mode, interval_us, controller_heartbeat_qpc. Invalid values
// fail open. Set interval and heartbeat before mode; default Observe, 8000 us.
// Accepted interval 1000..8000 us; native timing tests cover 1ms and 8ms endpoints.
namespace gameinput::probe::abi {
inline constexpr std::uint32_t magic = 0x31504947; // GIP1
inline constexpr std::uint32_t version = 1;
inline constexpr wchar_t mapping_prefix[] = L"Global\\GameInputProbe-v1-";
inline constexpr wchar_t security_sddl[] = L"D:P(A;;GA;;;SY)(A;;GA;;;BA)";
enum class Mode : std::int32_t { Observe = 0, Mitigate = 1 };
enum class Status : std::int32_t { Starting = 0, Running = 1, Stopped = 2, Busy = 3 };
struct alignas(8) Shared {
    std::uint32_t magic_value;                 // 0
    std::uint32_t abi_version;                 // 4
    std::uint32_t struct_bytes;                // 8
    std::uint32_t pid;                         // 12
    alignas(4) volatile std::int32_t mode;      // 16, wrapper writable
    volatile std::int32_t interval_us;          // 20, wrapper writable
    volatile std::int32_t status;               // 24
    std::uint32_t reserved;                    // 28
    std::uint64_t qpc_frequency;                // 32, immutable
    std::uint64_t start_qpc;                    // 40, immutable
    std::uint64_t start_cpu_100ns;              // 48, kernel + user process CPU
    volatile std::int64_t sample_qpc;           // 56, 250ms housekeeping/ProbeSample
    volatile std::int64_t process_cpu_100ns;    // 64, 250ms housekeeping/ProbeSample
    volatile std::int64_t calls;                // 72, exact IOCTL/size tuple
    volatile std::int64_t sync_success;         // 80, immediate TRUE, validated 24
    volatile std::int64_t pending;              // 88, counted ONLY, never read buffers
    volatile std::int64_t errors;               // 96
    volatile std::int64_t unobserved;           // 104, short/unreadable/unvalidated
    volatile std::int64_t unchanged;            // 112, entire 24 bytes
    volatile std::int64_t throttled;            // 120
    volatile std::int64_t delay_qpc;            // 128, actual elapsed delay
    volatile std::int64_t ioctl_qpc;            // 136, real call latency sum
    volatile std::int64_t state_drops;          // 144, bounded table/lock contention
    volatile std::int64_t closes;               // 152, successful CloseHandle
    wchar_t image_path[512];                   // 160
    wchar_t module_path[512];                  // 1184
    std::uint8_t image_sha256[32];              // 2208
    std::uint8_t module_sha256[32];             // 2240
    std::uint16_t image_version[4];             // 2272
    std::uint16_t module_version[4];            // 2280
    volatile std::int64_t controller_heartbeat_qpc; // 2288, wrapper writable
};
static_assert(offsetof(Shared, calls) == 72);
static_assert(offsetof(Shared, image_path) == 160);
#ifdef _WIN32
static_assert(sizeof(wchar_t) == 2);
static_assert(sizeof(Shared) == 2296);
#endif
// DWORD WINAPI ProbeSample(void* = nullptr): update QPC/CPU outside hotpath.
// ETW provider {B91B050B-64B5-4E3B-9A2F-42046D48E9CE}, name GameInputProbe.
// IOCTL events contain PID/TID/QPC/handle/latency/result/error/first_word/hash/streak;
// first_word is bytes[0..3], NOT a decoded packet number. Packet layout is not
// assumed. input_flag3 is byte3 of the four-byte input, SEH read before original;
// callsite_va is the original DeviceIoControl return address; resolve offline
// against wrapper-captured module base/size (never resolve modules on hotpath).
// input_flag_valid=false means unreadable. Observe has no intentional delay;
// QPC/locks/counters/ETW still add measurement overhead.
// FALSE/pending calls have packet/hash/streak zero (unobserved). TRUE with an
// OVERLAPPED is validated with GetOverlappedResult(..., FALSE); its original
// bytesReturned is never used or changed. FALSE/pending never invokes that API.
// Before enabling mitigation, write current target-QPC to heartbeat then mode=1.
// Refresh heartbeat at least every 500 ms. Missing/future/>2-second-old heartbeat
// atomically reverts mode to Observe; re-enabling requires a fresh heartbeat.
}
