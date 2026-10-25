#include <Windows.h>
#include "controller/remote_image.hpp"
#include "build_identity.hpp"
#include <cstdlib>
#include <iostream>
#define CHECK(x) do { if(!(x)) {std::cerr << __LINE__ << ": " #x "\n"; std::exit(1);} } while(0)
int main(int argc,char** argv) {
    CHECK(argc==2);
    auto dll=LoadLibraryA(argv[1]); CHECK(dll);
    const auto* dos=reinterpret_cast<const IMAGE_DOS_HEADER*>(dll);
    const auto* nt=reinterpret_cast<const IMAGE_NT_HEADERS64*>(reinterpret_cast<const char*>(dll)+dos->e_lfanew);
    using gameinput::remote_image::Image;
    Image image(GetCurrentProcess(),reinterpret_cast<std::uintptr_t>(dll),nt->OptionalHeader.SizeOfImage);
    CHECK(image.build_matches(GAMEINPUT_BUILD_ID));
    CHECK(!image.build_matches("different-built-image"));
    CHECK(image.function("ProbeStart")==reinterpret_cast<void*>(GetProcAddress(dll,"ProbeStart")));
    CHECK(image.function("ProbeStop")==reinterpret_cast<void*>(GetProcAddress(dll,"ProbeStop")));
    bool refused=false; try {image.function("missing");} catch(...) {refused=true;} CHECK(refused);
    refused=false; try {image.function("ProbeBuildId");} catch(...) {refused=true;} CHECK(refused);
    refused=false; try {Image bad(GetCurrentProcess(),reinterpret_cast<std::uintptr_t>(dll),4096);} catch(...) {refused=true;} CHECK(refused);
    FreeLibrary(dll);
    std::cout << "Loaded-image exports, build mismatch, executable-page and bounds checks passed\n";
}
