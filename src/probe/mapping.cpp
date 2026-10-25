#include "mapping.hpp"
#include <AclAPI.h>
#include <winternl.h>
#include <array>

namespace gameinput::probe {
DWORD validate_mapping(HANDLE handle) noexcept {
    using QuerySection = NTSTATUS (NTAPI*)(HANDLE, int, void*, ULONG, ULONG*);
    using QueryObject = NTSTATUS (NTAPI*)(HANDLE, int, void*, ULONG, ULONG*);
    struct SectionBasic { void* base; ULONG attributes; LARGE_INTEGER size; };
    const auto ntdll = GetModuleHandleW(L"ntdll.dll");
    const auto section = reinterpret_cast<QuerySection>(GetProcAddress(ntdll, "NtQuerySection"));
    const auto object = reinterpret_cast<QueryObject>(GetProcAddress(ntdll, "NtQueryObject"));
    if (!section || !object) return ERROR_PROC_NOT_FOUND;
    SectionBasic basic{};
    SYSTEM_INFO system_info{}; GetSystemInfo(&system_info);
    const auto native_size = ((sizeof(abi::Shared) + system_info.dwPageSize - 1) / system_info.dwPageSize) * system_info.dwPageSize;
    if (section(handle, 0, &basic, sizeof(basic), nullptr) < 0 || basic.size.QuadPart != static_cast<LONGLONG>(native_size))
        return ERROR_INVALID_DATA;
    alignas(void*) std::array<BYTE, 1024> name_buffer{};
    if (object(handle, 1, name_buffer.data(), static_cast<ULONG>(name_buffer.size()), nullptr) < 0)
        return ERROR_INVALID_HANDLE;
    const auto* name = reinterpret_cast<const UNICODE_STRING*>(name_buffer.data());
    wchar_t expected[128]{};
    swprintf_s(expected, L"\\BaseNamedObjects\\GameInputProbe-v1-%lu", GetCurrentProcessId());
    const auto expected_length = wcslen(expected);
    const auto start = reinterpret_cast<std::uintptr_t>(name_buffer.data());
    const auto pointer = reinterpret_cast<std::uintptr_t>(name->Buffer);
    if (name->Length != expected_length * sizeof(wchar_t) || pointer < start ||
        pointer > start + name_buffer.size() - name->Length ||
        CompareStringOrdinal(name->Buffer, name->Length / sizeof(wchar_t), expected,
                             static_cast<int>(expected_length), TRUE) != CSTR_EQUAL) return ERROR_INVALID_NAME;
    return validate_mapping_security(handle);
}
DWORD validate_mapping_security(HANDLE handle) noexcept {
    PACL acl{}; PSECURITY_DESCRIPTOR descriptor{};
    auto error = GetSecurityInfo(handle, SE_KERNEL_OBJECT, DACL_SECURITY_INFORMATION, nullptr, nullptr,
                                  &acl, nullptr, &descriptor);
    if (error) return error;
    SECURITY_DESCRIPTOR_CONTROL control{}; DWORD revision{};
    bool okay = GetSecurityDescriptorControl(descriptor, &control, &revision) &&
        (control & SE_DACL_PROTECTED) && acl && IsValidAcl(acl) && acl->AceCount == 2;
    BYTE admin[SECURITY_MAX_SID_SIZE]{}, system[SECURITY_MAX_SID_SIZE]{};
    DWORD admin_bytes = sizeof(admin), system_bytes = sizeof(system);
    okay = okay && CreateWellKnownSid(WinBuiltinAdministratorsSid, nullptr, admin, &admin_bytes) &&
        CreateWellKnownSid(WinLocalSystemSid, nullptr, system, &system_bytes);
    bool has_admin = false, has_system = false;
    for (DWORD i = 0; okay && i < 2; ++i) {
        void* address{};
        if (!GetAce(acl, i, &address)) { okay = false; break; }
        auto* ace = static_cast<ACCESS_ALLOWED_ACE*>(address);
        if (ace->Header.AceType != ACCESS_ALLOWED_ACE_TYPE || ace->Header.AceFlags != 0 ||
            (ace->Mask != GENERIC_ALL && ace->Mask != SECTION_ALL_ACCESS)) { okay = false; break; }
        PSID sid = &ace->SidStart;
        if (!IsValidSid(sid)) { okay = false; break; }
        if (EqualSid(sid, admin) && !has_admin) has_admin = true;
        else if (EqualSid(sid, system) && !has_system) has_system = true;
        else okay = false;
    }
    LocalFree(descriptor);
    return okay && has_admin && has_system ? ERROR_SUCCESS : ERROR_ACCESS_DENIED;
}
}
