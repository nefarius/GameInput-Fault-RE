#pragma once
#include <array>
#include <cstdint>
#include <cstring>
#include <limits>

namespace gameinput::probe {
inline constexpr std::uint32_t target_ioctl = 0x8000e388u;
inline constexpr std::size_t packet_bytes = 24;
inline constexpr std::size_t state_capacity = 128;
struct Decision {
    bool tracked{};
    bool unchanged{};
    std::uint64_t streak{};
    std::uint64_t delay{};
};
// Caller serializes access. Fixed storage, no allocation or eviction: saturation
// fails open. Clock units are supplied by the caller (QPC on Windows).
class Policy {
    struct Entry {
        std::uintptr_t handle{};
        bool used{};
        std::array<std::uint8_t, packet_bytes> packet{};
        std::uint64_t last_release{};
        std::uint64_t streak{};
    };
    std::array<Entry, state_capacity> entries_{};
public:
    void clear() noexcept { entries_ = {}; }
    void close(std::uintptr_t handle) noexcept {
        for (auto& e : entries_) if (e.used && e.handle == handle) e = {};
    }
    Decision observe(std::uintptr_t handle, const std::array<std::uint8_t, packet_bytes>& packet,
                     std::uint64_t now, std::uint64_t interval, bool mitigate) noexcept {
        Entry* free = nullptr;
        for (auto& e : entries_) {
            if (!e.used) { if (!free) free = &e; continue; }
            if (e.handle != handle) continue;
            const bool unchanged = e.packet == packet;
            const auto elapsed = now >= e.last_release ? now - e.last_release : 0;
            const auto delay = mitigate && unchanged && elapsed < interval ? interval - elapsed : 0;
            e.packet = packet;
            e.streak = unchanged ? (e.streak == (std::numeric_limits<std::uint64_t>::max)() ? e.streak : e.streak + 1) : 0;
            e.last_release = now + delay;
            return {true, unchanged, e.streak, delay};
        }
        if (!free) return {};
        *free = {handle, true, packet, now, 0};
        return {true, false, 0, 0};
    }
};
inline bool valid_interval(std::int32_t us) noexcept { return us >= 1000 && us <= 8000; }
inline std::uint64_t packet_hash(const std::array<std::uint8_t, packet_bytes>& bytes) noexcept {
    std::uint64_t h = 14695981039346656037ull;
    for (auto b : bytes) { h ^= b; h *= 1099511628211ull; }
    return h;
}
}
