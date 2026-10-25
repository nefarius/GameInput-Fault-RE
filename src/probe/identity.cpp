#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include "identity.hpp"
#include <bcrypt.h>
#include <ShlObj.h>
#include <array>
#include <cstring>
#include <string>
#include <vector>

namespace gameinput::probe {
namespace {
bool same(const std::wstring& a, const std::wstring& b) {
    return CompareStringOrdinal(a.c_str(), -1, b.c_str(), -1, TRUE) == CSTR_EQUAL;
}
bool canonical(const wchar_t* path, std::wstring& result) {
    HANDLE h = CreateFileW(path, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    wchar_t value[1024]{};
    const auto n = GetFinalPathNameByHandleW(h, value, 1024, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    CloseHandle(h);
    if (!n || n >= 1024) return false;
    result = value;
    if (result.rfind(L"\\\\?\\", 0) == 0) result.erase(0, 4);
    return true;
}
bool matches(const std::wstring& actual, const std::wstring& expected) {
    std::wstring resolved;
    return canonical(expected.c_str(), resolved) && same(actual, resolved);
}
bool x64_module(HMODULE handle) noexcept {
    __try {
        auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(handle);
        if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew <= 0 || dos->e_lfanew > 1024 * 1024) return false;
        auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(reinterpret_cast<const BYTE*>(handle) + dos->e_lfanew);
        return nt->Signature == IMAGE_NT_SIGNATURE && nt->FileHeader.Machine == IMAGE_FILE_MACHINE_AMD64;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool hash_matches(const std::uint8_t (&hash)[32], const char* expected) noexcept {
    constexpr char hex[] = "0123456789abcdef";
    for (size_t i = 0; i < 32; ++i) {
        if (hex[hash[i] >> 4] != expected[i * 2] || hex[hash[i] & 15] != expected[i * 2 + 1]) return false;
    }
    return true;
}
bool version_matches(const std::uint16_t (&version)[4], bool inbox) noexcept {
    const std::array<std::uint16_t, 4> expected = inbox ?
        std::array<std::uint16_t, 4>{0, 2309, 26100, 9278} : std::array<std::uint16_t, 4>{3, 5, 270, 0};
    for (size_t i = 0; i < 4; ++i) if (version[i] != expected[i]) return false;
    return true;
}
bool metadata(const std::wstring& path, std::uint8_t (&hash)[32], std::uint16_t (&version)[4]) {
    DWORD ignored{};
    const DWORD count = GetFileVersionInfoSizeW(path.c_str(), &ignored);
    if (!count || count > 1024 * 1024) return false;
    std::vector<std::uint8_t> info(count);
    VS_FIXEDFILEINFO* fixed{}; UINT fixed_size{};
    if (!GetFileVersionInfoW(path.c_str(), 0, count, info.data()) ||
        !VerQueryValueW(info.data(), L"\\", reinterpret_cast<LPVOID*>(&fixed), &fixed_size) ||
        fixed_size < sizeof(*fixed) || fixed->dwSignature != 0xfeef04bd) return false;
    version[0] = HIWORD(fixed->dwFileVersionMS); version[1] = LOWORD(fixed->dwFileVersionMS);
    version[2] = HIWORD(fixed->dwFileVersionLS); version[3] = LOWORD(fixed->dwFileVersionLS);
    BCRYPT_ALG_HANDLE algorithm{}; BCRYPT_HASH_HANDLE digest{};
    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0) return false;
    bool okay = BCryptCreateHash(algorithm, &digest, nullptr, 0, nullptr, 0, 0) >= 0;
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE,
                              nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    okay = okay && file != INVALID_HANDLE_VALUE;
    std::array<UCHAR, 16384> buffer{};
    while (okay) {
        DWORD bytes{};
        if (!ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()), &bytes, nullptr)) { okay = false; break; }
        if (!bytes) break;
        if (BCryptHashData(digest, buffer.data(), bytes, 0) < 0) { okay = false; break; }
    }
    if (okay) okay = BCryptFinishHash(digest, hash, 32, 0) >= 0;
    if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
    if (digest) BCryptDestroyHash(digest);
    BCryptCloseAlgorithmProvider(algorithm, 0);
    return okay;
}
}
DWORD identify(abi::Shared& shared) noexcept {
    try {
        wchar_t image_name[1024]{}, system_path[512]{};
        const auto image_n = GetModuleFileNameW(nullptr, image_name, 1024);
        const auto system_n = GetSystemDirectoryW(system_path, 512);
        if (!image_n || image_n >= 1024 || !system_n || system_n >= 512) return ERROR_BAD_PATHNAME;
        PWSTR program_files{};
        const auto hr = SHGetKnownFolderPath(FOLDERID_ProgramFiles, KF_FLAG_DEFAULT, nullptr, &program_files);
        if (FAILED(hr)) return ERROR_BAD_PATHNAME;
        const std::wstring redist_dir = std::wstring(program_files) + L"\\Microsoft GameInput\\x64\\";
        CoTaskMemFree(program_files);
        const std::wstring system_dir = std::wstring(system_path) + L"\\";
        std::wstring image;
        if (!canonical(image_name, image)) return ERROR_BAD_PATHNAME;
        const bool inbox = matches(image, system_dir + L"GameInputSvc.exe");
        const bool redist = matches(image, redist_dir + L"GameInputRedistService.exe");
        if (!inbox && !redist) return ERROR_ACCESS_DENIED;
        std::wstring module;
        const std::wstring name = inbox ? L"GameInput.dll" : L"GameInputRedist.dll";
        // Full paths make selection deterministic when two same-name redist
        // copies coexist: System32 first, then the Program Files x64 copy.
        for (const std::wstring& expected : {system_dir + name, redist_dir + name}) {
            if (inbox && expected != system_dir + name) continue;
            HMODULE handle = GetModuleHandleW(expected.c_str());
            if (!handle) continue;
            wchar_t module_name[1024]{};
            const auto n = GetModuleFileNameW(handle, module_name, 1024);
            std::wstring candidate;
            if (!n || n >= 1024 || !canonical(module_name, candidate)) continue;
            if (!matches(candidate, expected)) continue;
            if (!x64_module(handle)) continue;
            module = candidate; break;
        }
        if (module.empty()) return ERROR_MOD_NOT_FOUND;
        if (image.size() >= 512 || module.size() >= 512) return ERROR_BUFFER_OVERFLOW;
        if (!metadata(image, shared.image_sha256, shared.image_version) ||
            !metadata(module, shared.module_sha256, shared.module_version)) return ERROR_INVALID_DATA;
        if (!version_matches(shared.image_version, inbox) || !version_matches(shared.module_version, inbox) ||
            !hash_matches(shared.image_sha256, inbox ?
                "83ba5166dd6397ade67f4b6fddae6be61a694f487ed88ea83ee204f20be6d075" :
                "1cd8e575f585de38d64b71b5a63a55ba4522d2f47e633091b660b81755db6b3b") ||
            !hash_matches(shared.module_sha256, inbox ?
                "f9f5adbde4a2883b9b307bb1848a120094904578d92b21100828bd83f7b77cb6" :
                "6d3650dbeea5f8c639972537dbaed3f2bb465561e63d34fa9661902f24cb9686")) return ERROR_REVISION_MISMATCH;
        wcscpy_s(shared.image_path, image.c_str()); wcscpy_s(shared.module_path, module.c_str());
        return ERROR_SUCCESS;
    } catch (...) { return ERROR_NOT_ENOUGH_MEMORY; }
}
}
