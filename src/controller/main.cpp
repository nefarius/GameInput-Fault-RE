#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <Windows.h>
#include <TlHelp32.h>
#include <bcrypt.h>
#include <wintrust.h>
#include <softpub.h>
#include <wincrypt.h>
#include <ShlObj.h>
#include <sddl.h>
#include <array>
#include <vector>
#include <string>
#include <sstream>
#include <iostream>
#include <stdexcept>
#include <memory>
#include <cwctype>
#include "../probe/protocol.hpp"
#include "remote_image.hpp"
#include "build_identity.hpp"
namespace abi = gameinput::probe::abi;
namespace {
volatile LONG interrupted{};
BOOL WINAPI interrupt_handler(DWORD event){
    if(event==CTRL_C_EVENT||event==CTRL_BREAK_EVENT||event==CTRL_CLOSE_EVENT){InterlockedExchange(&interrupted,1);return TRUE;}return FALSE;
}
struct Failure : std::runtime_error {
    DWORD code;
    Failure(DWORD value, const char* message) : std::runtime_error(message), code(value ? value : ERROR_GEN_FAILURE) {}
};
[[noreturn]] void fail(const char* text) { const DWORD error = GetLastError(); throw Failure(error, text); }
struct Handle {
    HANDLE value{};
    explicit Handle(HANDLE h = nullptr):value(h){}
    ~Handle(){ if(value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
    Handle(const Handle&)=delete; Handle& operator=(const Handle&)=delete;
};
bool same(const std::wstring& a, const std::wstring& b) {
    return CompareStringOrdinal(a.c_str(), -1, b.c_str(), -1, TRUE) == CSTR_EQUAL;
}
std::wstring canonical(const std::wstring& path) {
    Handle file(CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                            nullptr, OPEN_EXISTING, 0, nullptr));
    if(file.value==INVALID_HANDLE_VALUE) fail("Open canonical path");
    wchar_t text[32768]; DWORD n=GetFinalPathNameByHandleW(file.value,text,32768,FILE_NAME_NORMALIZED);
    if(!n || n>=32768) fail("Canonical path");
    std::wstring result(text,n); if(result.rfind(L"\\\\?\\",0)==0) result.erase(0,4); return result;
}
std::string utf8(const std::wstring& s) {
    if(s.empty()) return {};
    int count=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,s.data(),static_cast<int>(s.size()),nullptr,0,nullptr,nullptr);
    if(!count) fail("UTF8 conversion");
    std::string result(count,0); WideCharToMultiByte(CP_UTF8,0,s.data(),static_cast<int>(s.size()),result.data(),count,nullptr,nullptr); return result;
}
std::string json(const std::wstring& text) {
    std::string result="\"";
    for(unsigned char ch: utf8(text)) {
        if(ch=='"' || ch=='\\') {result+='\\';result+=ch;}
        else if(ch<32) { const char* hex="0123456789abcdef"; result+="\\u00";result+=hex[ch>>4];result+=hex[ch&15]; }
        else result+=ch;
    }
    return result+'"';
}
std::string hash_file(const std::wstring& path) {
    BCRYPT_ALG_HANDLE alg{}; BCRYPT_HASH_HANDLE hash{};
    if(BCryptOpenAlgorithmProvider(&alg,BCRYPT_SHA256_ALGORITHM,nullptr,0)<0) throw Failure(ERROR_INVALID_DATA,"SHA256 provider");
    struct Cleanup {BCRYPT_ALG_HANDLE a; BCRYPT_HASH_HANDLE& h; ~Cleanup(){if(h)BCryptDestroyHash(h);BCryptCloseAlgorithmProvider(a,0);}} cleanup{alg,hash};
    if(BCryptCreateHash(alg,&hash,nullptr,0,nullptr,0,0)<0) throw Failure(ERROR_INVALID_DATA,"SHA256 create");
    Handle file(CreateFileW(path.c_str(),GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_DELETE,nullptr,OPEN_EXISTING,0,nullptr));
    if(file.value==INVALID_HANDLE_VALUE) fail("Open hash file");
    std::array<UCHAR,65536> data; DWORD n{};
    for(;;){ if(!ReadFile(file.value,data.data(),static_cast<DWORD>(data.size()),&n,nullptr)) fail("Read hash file"); if(!n)break;
        if(BCryptHashData(hash,data.data(),n,0)<0) throw Failure(ERROR_INVALID_DATA,"SHA256 update"); }
    UCHAR digest[32]; if(BCryptFinishHash(hash,digest,32,0)<0) throw Failure(ERROR_INVALID_DATA,"SHA256 finish");
    std::string result; const char* hex="0123456789abcdef";
    for(auto b:digest){result+=hex[b>>4];result+=hex[b&15];} return result;
}
std::array<WORD,4> file_version(const std::wstring& path) {
    DWORD unused{}; auto n=GetFileVersionInfoSizeW(path.c_str(),&unused); if(!n)fail("File version size");
    std::vector<BYTE> bytes(n); if(!GetFileVersionInfoW(path.c_str(),0,n,bytes.data())) fail("File version");
    VS_FIXEDFILEINFO* f{};UINT size{};
    if(!VerQueryValueW(bytes.data(),L"\\",reinterpret_cast<void**>(&f),&size) || size<sizeof(*f) || f->dwSignature!=0xfeef04bd)throw Failure(ERROR_INVALID_DATA,"File version structure");
    return {HIWORD(f->dwFileVersionMS),LOWORD(f->dwFileVersionMS),HIWORD(f->dwFileVersionLS),LOWORD(f->dwFileVersionLS)};
}
void microsoft_signature(const std::wstring& path) {
    WINTRUST_FILE_INFO file{sizeof(file)};file.pcwszFilePath=path.c_str();
    WINTRUST_DATA trust{sizeof(trust)};trust.dwUIChoice=WTD_UI_NONE;trust.fdwRevocationChecks=WTD_REVOKE_NONE;
    trust.dwUnionChoice=WTD_CHOICE_FILE;trust.pFile=&file;trust.dwStateAction=WTD_STATEACTION_VERIFY;
    GUID policy=WINTRUST_ACTION_GENERIC_VERIFY_V2;auto result=WinVerifyTrust(nullptr,&policy,&trust);
    bool microsoft=false;
    if(result==ERROR_SUCCESS){
        auto* provider=WTHelperProvDataFromStateData(trust.hWVTStateData);
        auto* signer=provider?WTHelperGetProvSignerFromChain(provider,0,FALSE,0):nullptr;
        if(signer && signer->csCertChain){wchar_t organization[256]{};
            if(CertGetNameStringW(signer->pasCertChain[0].pCert,CERT_NAME_ATTR_TYPE,0,
                                const_cast<char*>(szOID_ORGANIZATION_NAME),organization,256)>1)
                microsoft=wcscmp(organization,L"Microsoft Corporation")==0;
        }
    }
    trust.dwStateAction=WTD_STATEACTION_CLOSE;WinVerifyTrust(nullptr,&policy,&trust);
    if(result!=ERROR_SUCCESS || !microsoft)throw Failure(ERROR_INVALID_DATA,"Valid Microsoft signature required");
}
void enable_debug(){
    Handle token; if(!OpenProcessToken(GetCurrentProcess(),TOKEN_ADJUST_PRIVILEGES|TOKEN_QUERY,&token.value)) fail("Open debug token");
    TOKEN_PRIVILEGES privileges{};privileges.PrivilegeCount=1;
    if(!LookupPrivilegeValueW(nullptr,L"SeDebugPrivilege",&privileges.Privileges[0].Luid))fail("Lookup SeDebugPrivilege");
    privileges.Privileges[0].Attributes=SE_PRIVILEGE_ENABLED;
    SetLastError(ERROR_SUCCESS);BOOL okay=AdjustTokenPrivileges(token.value,FALSE,&privileges,0,nullptr,nullptr);
    DWORD error=GetLastError();if(!okay || error!=ERROR_SUCCESS)throw Failure(error,"Enable SeDebugPrivilege; administrator elevation required");
}
struct Module {std::wstring path;std::uintptr_t base{};DWORD size{};};
std::vector<Module> modules(DWORD pid){
    Handle list(CreateToolhelp32Snapshot(TH32CS_SNAPMODULE|TH32CS_SNAPMODULE32,pid));
    if(list.value==INVALID_HANDLE_VALUE)fail("Enumerate loaded modules");
    MODULEENTRY32W entry{sizeof(entry)};std::vector<Module> result;
    if(!Module32FirstW(list.value,&entry))fail("Read loaded modules");
    do { result.push_back({canonical(entry.szExePath),reinterpret_cast<std::uintptr_t>(entry.modBaseAddr),entry.modBaseSize}); } while(Module32NextW(list.value,&entry));
    DWORD error=GetLastError();if(error!=ERROR_NO_MORE_FILES)throw Failure(error,"Enumerate loaded modules continuation");return result;
}
struct Identity {std::wstring image,module;std::string image_hash,module_hash;std::array<WORD,4> image_version,module_version;};
Identity verify(HANDLE process,DWORD pid){
    USHORT machine{},native{};if(!IsWow64Process2(process,&machine,&native))fail("Query architecture");
    if(machine!=IMAGE_FILE_MACHINE_UNKNOWN || native!=IMAGE_FILE_MACHINE_AMD64)throw Failure(ERROR_BAD_EXE_FORMAT,"Only x64 processes supported");
    PROCESS_PROTECTION_LEVEL_INFORMATION protection{};
    if(!GetProcessInformation(process,ProcessProtectionLevelInfo,&protection,sizeof(protection)))fail("Query process protection");
    if(protection.ProtectionLevel!=PROTECTION_LEVEL_NONE)throw Failure(ERROR_ACCESS_DENIED,"Protected targets refused");
    wchar_t image[32768];DWORD size=32768;if(!QueryFullProcessImageNameW(process,0,image,&size))fail("Query image path");
    Identity identity;identity.image=canonical(std::wstring(image,size));
    wchar_t system[32768];if(!GetSystemDirectoryW(system,32768))fail("System directory");
    PWSTR files{};if(FAILED(SHGetKnownFolderPath(FOLDERID_ProgramFiles,0,nullptr,&files)))throw Failure(ERROR_PATH_NOT_FOUND,"ProgramFiles directory");
    std::wstring redist=std::wstring(files)+L"\\Microsoft GameInput\\x64\\";CoTaskMemFree(files);
    std::wstring sys=std::wstring(system)+L"\\";
    bool inbox=same(identity.image,sys+L"GameInputSvc.exe");
    if(!inbox && !same(identity.image,redist+L"GameInputRedistService.exe"))throw Failure(ERROR_ACCESS_DENIED,"Exact GameInput executable required");
    microsoft_signature(identity.image);identity.image_hash=hash_file(identity.image);identity.image_version=file_version(identity.image);
    const std::string expected_image_hash=inbox?"83ba5166dd6397ade67f4b6fddae6be61a694f487ed88ea83ee204f20be6d075":"1cd8e575f585de38d64b71b5a63a55ba4522d2f47e633091b660b81755db6b3b";
    const std::array<WORD,4> expected_image_version=inbox?std::array<WORD,4>{0,2309,26100,9278}:std::array<WORD,4>{3,5,270,0};
    if(identity.image_hash!=expected_image_hash || identity.image_version!=expected_image_version)throw Failure(ERROR_REVISION_MISMATCH,"Unknown GameInput executable hash/version");
    auto loaded=modules(pid);bool required=false;
    for(const auto& module:loaded){
        auto name=module.path.substr(module.path.find_last_of(L"\\/")+1);
        bool api=same(name,L"GameInput.dll"),red=same(name,L"GameInputRedist.dll");if(!api&&!red)continue;
        if(!same(module.path,sys+name) && !(red&&same(module.path,redist+name)))throw Failure(ERROR_ACCESS_DENIED,"Unexpected loaded GameInput DLL path");
        microsoft_signature(module.path);auto hash=hash_file(module.path);auto version=file_version(module.path);
        const std::string expected=api?"f9f5adbde4a2883b9b307bb1848a120094904578d92b21100828bd83f7b77cb6":"6d3650dbeea5f8c639972537dbaed3f2bb465561e63d34fa9661902f24cb9686";
        const std::array<WORD,4> expected_version=api?std::array<WORD,4>{0,2309,26100,9278}:std::array<WORD,4>{3,5,270,0};
        if(hash!=expected || version!=expected_version)throw Failure(ERROR_REVISION_MISMATCH,"Unknown GameInput hash/version");
        if((inbox&&api)||(!inbox&&red)){
            // Both known redist copies may be mapped. Validate all copies, then
            // choose System32 consistently with probe identity initialization.
            if(!required || same(module.path,sys+name)){identity.module=module.path;identity.module_hash=hash;identity.module_version=version;}
            required=true;
        }
    }
    if(!required)throw Failure(ERROR_MOD_NOT_FOUND,"Required GameInput DLL not loaded");return identity;
}
std::wstring fixed_probe(){
    wchar_t exe[32768];auto n=GetModuleFileNameW(nullptr,exe,32768);if(!n||n>=32768)fail("Controller image path");
    std::wstring path(exe,n);return canonical(path.substr(0,path.find_last_of(L"\\/")+1)+L"GameInputProbe.dll");
}
void remote(HANDLE process,DWORD pid,const char* export_name,void* parameter=nullptr,bool* dispatched=nullptr,bool* completed=nullptr){
    const auto probe=fixed_probe();Module remote_module;bool found=false;
    for(const auto& m:modules(pid))if(same(m.path,probe)){if(found)throw Failure(ERROR_INVALID_DATA,"Ambiguous loaded probe");remote_module=m;found=true;}
    if(!found)throw Failure(ERROR_MOD_NOT_FOUND,"Fixed built probe not loaded by Injector");
    gameinput::remote_image::Image loaded(process,remote_module.base,remote_module.size);
    if(!loaded.build_matches(GAMEINPUT_BUILD_ID))throw Failure(ERROR_REVISION_MISMATCH,"Loaded probe build differs from controller; no remote call made");
    auto address=loaded.function(export_name);
    Handle thread(CreateRemoteThread(process,nullptr,0,reinterpret_cast<LPTHREAD_START_ROUTINE>(address),parameter,0,nullptr));
    if(!thread.value)fail("Call fixed probe API");
    if(dispatched)*dispatched=true;
    DWORD wait=WaitForSingleObject(thread.value,15000);
    if(wait==WAIT_TIMEOUT)throw Failure(ERROR_TIMEOUT,"Probe API timeout; module retained; no forced unload");
    if(wait!=WAIT_OBJECT_0)fail("Wait fixed probe API");
    DWORD result{};if(!GetExitCodeThread(thread.value,&result))fail("Probe API result");
    if(completed)*completed=true;
    if(result!=ERROR_SUCCESS && !(result==ERROR_ALREADY_EXISTS && !parameter && std::string(export_name)=="ProbeStart"))throw Failure(result,"Probe API returned error");
}
std::string bytes_hex(const std::uint8_t* bytes){std::string result;const char* hex="0123456789abcdef";for(int i=0;i<32;++i){result+=hex[bytes[i]>>4];result+=hex[bytes[i]&15];}return result;}
struct CaptureStopGuard {
    HANDLE process;DWORD pid;bool active{};
    ~CaptureStopGuard(){if(active){try{remote(process,pid,"ProbeStop");}catch(...){}}}
};
std::wstring bounded(const wchar_t* path){size_t n=0;while(n<512&&path[n])++n;if(n==512)throw Failure(ERROR_INVALID_DATA,"Unterminated shared path");return {path,n};}
std::string snapshot(abi::Shared* s,const Identity& identity,DWORD pid,const std::wstring& action,const std::wstring& stage=L""){
    if(s->magic_value!=abi::magic||s->abi_version!=abi::version||s->struct_bytes!=sizeof(abi::Shared)||s->pid!=pid ||
       !same(bounded(s->image_path),identity.image)||!same(bounded(s->module_path),identity.module)||
       bytes_hex(s->image_sha256)!=identity.image_hash || bytes_hex(s->module_sha256)!=identity.module_hash)
        throw Failure(ERROR_INVALID_DATA,"Probe handshake identity/ABI mismatch");
    if(action==L"mitigate" && s->status!=static_cast<LONG>(abi::Status::Running))throw Failure(ERROR_NOT_READY,"Probe hooks not running");
    LARGE_INTEGER now{};QueryPerformanceCounter(&now);
    // A stopped wrapper cannot keep mitigation alive: every capture refreshes
    // this lease, and the hook reverts to observation after two seconds.
    if(action==L"mitigate" || (action==L"snapshot" && s->mode==1))InterlockedExchange64(reinterpret_cast<volatile LONG64*>(&s->controller_heartbeat_qpc),now.QuadPart);
    if(action==L"mitigate") { InterlockedExchange(reinterpret_cast<volatile LONG*>(&s->interval_us),8000);InterlockedExchange(reinterpret_cast<volatile LONG*>(&s->mode),1); }
    if(action==L"observe")InterlockedExchange(reinterpret_cast<volatile LONG*>(&s->mode),0);
    std::ostringstream out;out<<"{";bool first=true;
    auto number=[&](const char* key,auto value){if(!first)out<<',';first=false;out<<'"'<<key<<"\":"<<value;};
    auto text=[&](const char* key,const std::wstring& value){if(!first)out<<',';first=false;out<<'"'<<key<<"\":"<<json(value);};
    auto atomic64=[](volatile std::int64_t& value){return InterlockedCompareExchange64(reinterpret_cast<volatile LONG64*>(&value),0,0);};
    auto atomic32=[](volatile std::int32_t& value){return InterlockedCompareExchange(reinterpret_cast<volatile LONG*>(&value),0,0);};
#define IMM(x) number(#x,s->x)
#define A64(x) number(#x,atomic64(s->x))
#define A32(x) number(#x,atomic32(s->x))
    IMM(magic_value);IMM(abi_version);IMM(struct_bytes);IMM(pid);IMM(qpc_frequency);IMM(start_qpc);IMM(start_cpu_100ns);
    A32(mode);A32(interval_us);A32(status);A64(sample_qpc);A64(process_cpu_100ns);A64(calls);A64(sync_success);A64(pending);A64(errors);A64(unobserved);A64(unchanged);A64(throttled);A64(delay_qpc);A64(ioctl_qpc);A64(state_drops);A64(closes);A64(controller_heartbeat_qpc);
#undef IMM
#undef A64
#undef A32
    text("image_path",bounded(s->image_path));text("module_path",bounded(s->module_path));
    text("image_sha256",std::wstring(identity.image_hash.begin(),identity.image_hash.end()));text("module_sha256",std::wstring(identity.module_hash.begin(),identity.module_hash.end()));
    auto version=[](const std::array<WORD,4>& v){return std::to_wstring(v[0])+L"."+std::to_wstring(v[1])+L"."+std::to_wstring(v[2])+L"."+std::to_wstring(v[3]);};
    text("image_version",version(identity.image_version));text("module_version",version(identity.module_version));
    if(!stage.empty())text("capture_stage",stage);
    number("unload_safe",0);number("retained_until_exit",1);out<<'}';return out.str();
}
}
int wmain(int argc,wchar_t** argv){
    try {
        if((argc!=5&&argc!=7)||wcscmp(argv[1],L"--pid")||wcscmp(argv[3],L"--action"))throw Failure(ERROR_INVALID_PARAMETER,"Usage: controller --pid discovered-id --action fixed-action [--seconds 1..300]");
        std::wstring digits=argv[2];if(digits.empty()||digits.size()>10||digits.find_first_not_of(L"0123456789")!=std::wstring::npos)throw Failure(ERROR_INVALID_PARAMETER,"Invalid internal process ID");
        auto wide=std::stoull(digits);if(!wide||wide>MAXDWORD)throw Failure(ERROR_INVALID_PARAMETER,"Invalid internal process ID");DWORD pid=static_cast<DWORD>(wide);
        std::wstring action=argv[4];bool capture=action==L"capture_observe"||action==L"capture_mitigate";
        if(action!=L"start"&&action!=L"stop"&&action!=L"snapshot"&&action!=L"observe"&&action!=L"mitigate"&&action!=L"verify"&&action!=L"failed_start_status"&&!capture)throw Failure(ERROR_INVALID_PARAMETER,"No arbitrary exports permitted");
        unsigned seconds=10;
        if(argc==7){if(!capture||wcscmp(argv[5],L"--seconds"))throw Failure(ERROR_INVALID_PARAMETER,"Duration accepted only for bounded capture");std::wstring value=argv[6];
            if(value.empty()||value.size()>3||value.find_first_not_of(L"0123456789")!=std::wstring::npos)throw Failure(ERROR_INVALID_PARAMETER,"Invalid capture duration");seconds=static_cast<unsigned>(std::stoul(value));
            if(seconds<1||seconds>300)throw Failure(ERROR_INVALID_PARAMETER,"Capture duration must be 1..300 seconds");}
        enable_debug();
        Handle process(OpenProcess(PROCESS_QUERY_INFORMATION|PROCESS_VM_READ|PROCESS_CREATE_THREAD|PROCESS_VM_OPERATION|PROCESS_VM_WRITE|PROCESS_DUP_HANDLE|SYNCHRONIZE,FALSE,pid));
        if(!process.value)fail("Open exact GameInput target");
        const auto identity=verify(process.value,pid);
        if(action==L"verify"){
            const auto probe=fixed_probe();bool loaded=false;for(const auto& m:modules(pid))if(same(m.path,probe))loaded=true;
            std::cout<<"{\"verified\":true,\"pid\":"<<pid<<",\"probe_loaded\":"<<(loaded?"true":"false")<<",\"image_path\":"<<json(identity.image)<<",\"module_path\":"<<json(identity.module)<<"}"<<std::endl;return 0;
        }
        Handle cancel;
        CaptureStopGuard capture_cleanup{process.value,pid};
        if(capture){
            PSECURITY_DESCRIPTOR descriptor{};
            if(!ConvertStringSecurityDescriptorToSecurityDescriptorW(abi::security_sddl,SDDL_REVISION_1,&descriptor,nullptr))fail("Capture cancellation descriptor");
            SECURITY_ATTRIBUTES attributes{sizeof(attributes),descriptor,FALSE};
            std::wstring cancel_name=L"Global\\GameInputProbeCaptureStop-v1-"+std::to_wstring(pid);
            cancel.value=CreateEventW(&attributes,TRUE,FALSE,cancel_name.c_str());DWORD event_error=GetLastError();LocalFree(descriptor);
            if(!cancel.value)throw Failure(event_error,"Capture cancellation event");
            if(event_error==ERROR_ALREADY_EXISTS)throw Failure(ERROR_BUSY,"A capture worker for this target already exists");
            capture_cleanup.active=true;
        }
        if(action==L"start"||capture){
            // Medium-integrity GameInput targets cannot create a Global section.
            // Create its protected object here, then transfer only a section handle
            // to the validated target; never relax the administrator/SYSTEM DACL.
            std::wstring section_name=std::wstring(abi::mapping_prefix)+std::to_wstring(pid);
            Handle existing(OpenFileMappingW(FILE_MAP_READ|FILE_MAP_WRITE,FALSE,section_name.c_str()));
            if(existing.value)remote(process.value,pid,"ProbeStart");
            else {
                DWORD open_error=GetLastError();if(open_error!=ERROR_FILE_NOT_FOUND)throw Failure(open_error,"Open existing secured section");
                PSECURITY_DESCRIPTOR descriptor{};
                if(!ConvertStringSecurityDescriptorToSecurityDescriptorW(abi::security_sddl,SDDL_REVISION_1,&descriptor,nullptr))fail("Section security descriptor");
                SECURITY_ATTRIBUTES attributes{sizeof(attributes),descriptor,FALSE};
                HANDLE raw=CreateFileMappingW(INVALID_HANDLE_VALUE,&attributes,PAGE_READWRITE,0,sizeof(abi::Shared),section_name.c_str());
                DWORD create_error=GetLastError();LocalFree(descriptor);Handle section(raw);
                if(!section.value)throw Failure(create_error,"Create secured Global section");
                if(create_error==ERROR_ALREADY_EXISTS)throw Failure(ERROR_ALREADY_EXISTS,"Concurrent section startup refused");
                HANDLE target_section{};
                if(!DuplicateHandle(GetCurrentProcess(),section.value,process.value,&target_section,0,FALSE,DUPLICATE_SAME_ACCESS))fail("Transfer secured section to exact target");
                // ProbeStart consumes the handle on every dispatched call, including
                // failure. Reclaim only if the remote thread was never started.
                bool dispatched=false,completed=false;
                try { remote(process.value,pid,"ProbeStart",target_section,&dispatched,&completed); }
                catch (...) {
                    if(!dispatched){HANDLE reclaimed{};
                        if(DuplicateHandle(process.value,target_section,GetCurrentProcess(),&reclaimed,0,FALSE,DUPLICATE_SAME_ACCESS|DUPLICATE_CLOSE_SOURCE))CloseHandle(reclaimed);
                    }
                    throw;
                }
            }
        }
        else if(action==L"stop"||action==L"failed_start_status")remote(process.value,pid,"ProbeStop");
        if(WaitForSingleObject(process.value,0)!=WAIT_TIMEOUT)throw Failure(ERROR_PROCESS_ABORTED,"Target exited during operation");
        std::wstring name=std::wstring(abi::mapping_prefix)+std::to_wstring(pid);
        Handle mapping(OpenFileMappingW(FILE_MAP_READ|FILE_MAP_WRITE,FALSE,name.c_str()));
        if(!mapping.value){
            DWORD error=GetLastError();
            if((action==L"stop"||action==L"failed_start_status") && error==ERROR_FILE_NOT_FOUND){
                if(action==L"failed_start_status")std::cout<<"{\"pid\":"<<pid<<",\"stopped\":true,\"never_started\":true,\"mapping_present\":false,\"unload_safe\":1,\"proof\":\"Fixed probe Stop returned zero and no persistent mapping exists; applies only to this probe ABI retaining mapping after successful start\"}"<<std::endl;
                else std::cout<<"{\"pid\":"<<pid<<",\"stop_succeeded\":true,\"mapping_present\":false,\"unload_safe\":false,\"retained_until_exit\":true}"<<std::endl;
                return 0;
            }
            throw Failure(error,"Open probe handshake mapping");
        }
        auto* shared=static_cast<abi::Shared*>(MapViewOfFile(mapping.value,FILE_MAP_READ|FILE_MAP_WRITE,0,0,sizeof(abi::Shared)));if(!shared)fail("Map probe handshake");
        struct View{void* pointer;~View(){UnmapViewOfFile(pointer);}}view{shared};
        // Validate before invoking sample or writing control values.
        (void)snapshot(shared,identity,pid,L"validate");
        if(capture){
            // One controller process per target for the entire phase. The probe's
            // existing housekeeping worker samples CPU/QPC; no per-sample target
            // threads or child processes can perturb process-notification paths.
            SetConsoleCtrlHandler(interrupt_handler,TRUE);
            try {
                auto selected=action==L"capture_mitigate"?L"mitigate":L"observe";
                std::cout<<snapshot(shared,identity,pid,selected,L"stabilization")<<std::endl;
                const auto begin=GetTickCount64();
                while(!InterlockedCompareExchange(&interrupted,0,0)){
                    if(WaitForSingleObject(cancel.value,250)==WAIT_OBJECT_0)break;
                    if(WaitForSingleObject(process.value,0)!=WAIT_TIMEOUT)throw Failure(ERROR_PROCESS_ABORTED,"Target exited during capture");
                    auto elapsed=GetTickCount64()-begin;
                    if(elapsed>=static_cast<ULONGLONG>(seconds+4)*1000)break;
                    auto stage=elapsed<2000?L"stabilization":elapsed<static_cast<ULONGLONG>(seconds+2)*1000?L"measurement":L"drain";
                    std::cout<<snapshot(shared,identity,pid,L"snapshot",stage)<<std::endl;
                }
                DWORD stop_error=ERROR_SUCCESS;bool stopped=false;
                for(int attempt=0;attempt<3&&!stopped;++attempt){try{remote(process.value,pid,"ProbeStop");stopped=true;}catch(const Failure& e){stop_error=e.code;Sleep(250);}}
                if(!stopped)throw Failure(stop_error,"Capture stop could not confirm detached hooks; module retained");
                capture_cleanup.active=false;
                std::cout<<snapshot(shared,identity,pid,L"validate",L"teardown")<<std::endl;
                return 0;
            }catch(...){try{remote(process.value,pid,"ProbeStop");}catch(...){}throw;}
        }
        if(action!=L"stop"&&action!=L"failed_start_status"&&action!=L"snapshot")remote(process.value,pid,"ProbeSample");
        std::cout<<snapshot(shared,identity,pid,action)<<std::endl;return 0;
    }catch(const Failure& error){std::cout<<"{\"error_code\":"<<error.code<<",\"error\":"<<json(std::wstring(error.what(),error.what()+strlen(error.what())))<<"}"<<std::endl;return 1;}
    catch(...){std::cout<<"{\"error_code\":13,\"error\":\"Invalid controller request or internal failure\"}"<<std::endl;return 1;}
}
