#pragma once
#include <Windows.h>
#include <array>
#include <cstdint>
#include <cstring>
#include <stdexcept>
#include <string>

namespace gameinput::remote_image {
// Resolve fixed exports from the loaded image itself. File paths do not prove
// that a mapped DLL is the build currently on disk.
class Image {
    HANDLE process_;
    std::uintptr_t base_;
    std::uint32_t bytes_;
    IMAGE_DATA_DIRECTORY exports_{};
    void read(std::uint32_t rva, void* output, std::size_t count) const {
        if (rva > bytes_ || count > bytes_ - rva) throw std::runtime_error("Remote image bounds");
        SIZE_T got{};
        if (!ReadProcessMemory(process_, reinterpret_cast<const void*>(base_ + rva), output, count, &got) || got != count)
            throw std::runtime_error("Remote image unreadable");
    }
    template<class T> T value(std::uint32_t rva) const { T v{}; read(rva, &v, sizeof(v)); return v; }
    std::string name(std::uint32_t rva) const {
        std::string result;
        for (unsigned i=0; i<128; ++i) {
            if (rva > bytes_ || i >= bytes_ - rva) break;
            const char c=value<char>(rva+i);
            if (!c) return result;
            result += c;
        }
        throw std::runtime_error("Unterminated remote export");
    }
public:
    Image(HANDLE process, std::uintptr_t base, std::uint32_t bytes):process_(process),base_(base),bytes_(bytes) {
        if (!base || bytes < sizeof(IMAGE_DOS_HEADER) || bytes > 64*1024*1024) throw std::runtime_error("Invalid probe image size");
        const auto dos=value<IMAGE_DOS_HEADER>(0);
        if (dos.e_magic!=IMAGE_DOS_SIGNATURE || dos.e_lfanew<=0 || dos.e_lfanew>1024*1024) throw std::runtime_error("Invalid probe DOS header");
        const auto nt=value<IMAGE_NT_HEADERS64>(static_cast<std::uint32_t>(dos.e_lfanew));
        if (nt.Signature!=IMAGE_NT_SIGNATURE || nt.FileHeader.Machine!=IMAGE_FILE_MACHINE_AMD64 ||
            nt.OptionalHeader.Magic!=IMAGE_NT_OPTIONAL_HDR64_MAGIC || nt.OptionalHeader.SizeOfImage!=bytes ||
            nt.OptionalHeader.NumberOfRvaAndSizes<=IMAGE_DIRECTORY_ENTRY_EXPORT) throw std::runtime_error("Invalid probe PE header");
        exports_=nt.OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT];
        if (!exports_.VirtualAddress || exports_.Size<sizeof(IMAGE_EXPORT_DIRECTORY) ||
            exports_.VirtualAddress>bytes || exports_.Size>bytes-exports_.VirtualAddress) throw std::runtime_error("Invalid probe export table");
    }
    std::uint32_t export_rva(const char* fixed_name) const {
        const auto table=value<IMAGE_EXPORT_DIRECTORY>(exports_.VirtualAddress);
        if (!table.NumberOfFunctions || table.NumberOfFunctions>4096 || table.NumberOfNames>4096)
            throw std::runtime_error("Invalid probe export counts");
        const auto check_array=[&](DWORD rva, DWORD count, std::size_t width) {
            if (rva>bytes_ || count>(bytes_-rva)/width) throw std::runtime_error("Invalid probe export array");
        };
        check_array(table.AddressOfNames,table.NumberOfNames,4);
        check_array(table.AddressOfNameOrdinals,table.NumberOfNames,2);
        check_array(table.AddressOfFunctions,table.NumberOfFunctions,4);
        for (DWORD i=0; i<table.NumberOfNames; ++i) {
            if (name(value<DWORD>(table.AddressOfNames+i*4))!=fixed_name) continue;
            const auto ordinal=value<WORD>(table.AddressOfNameOrdinals+i*2);
            if (ordinal>=table.NumberOfFunctions) throw std::runtime_error("Invalid probe export ordinal");
            const auto rva=value<DWORD>(table.AddressOfFunctions+ordinal*4);
            if (!rva || rva>=bytes_ || (rva>=exports_.VirtualAddress && rva-exports_.VirtualAddress<exports_.Size))
                throw std::runtime_error("Forwarded or invalid probe export refused");
            return rva;
        }
        throw std::runtime_error("Required loaded probe export absent");
    }
    bool build_matches(const char* expected) const {
        const auto count=std::strlen(expected)+1;
        if (count>128) return false;
        std::array<char,128> actual{};
        read(export_rva("ProbeBuildId"), actual.data(), count);
        return std::memcmp(actual.data(),expected,count)==0;
    }
    void* function(const char* fixed_name) const {
        const auto rva=export_rva(fixed_name);
        MEMORY_BASIC_INFORMATION info{};
        auto* address=reinterpret_cast<void*>(base_+rva);
        if (!VirtualQueryEx(process_,address,&info,sizeof(info)) || info.State!=MEM_COMMIT ||
            (info.Protect & (PAGE_GUARD|PAGE_NOACCESS)) ||
            !(info.Protect & (PAGE_EXECUTE|PAGE_EXECUTE_READ|PAGE_EXECUTE_READWRITE|PAGE_EXECUTE_WRITECOPY)))
            throw std::runtime_error("Probe export is not executable");
        return address;
    }
};
}
