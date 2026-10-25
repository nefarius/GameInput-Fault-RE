#include <Windows.h>
#include <detours.h>
#include <cstdlib>
#include <iostream>
namespace {
HANDLE lock_now, locked, release_heap;
__declspec(noinline) int original(int n) {volatile int value=n+17;return value*13;}
using Function=int(*)(int);
Function trampoline=original;
int hook(int n){return trampoline(n)+1;}
DWORD WINAPI heap_owner(void*) {
    WaitForSingleObject(lock_now,INFINITE);
    if(!HeapLock(GetProcessHeap())) return 1;
    SetEvent(locked);
    WaitForSingleObject(release_heap,INFINITE);
    return HeapUnlock(GetProcessHeap())?0:2;
}
}
int main(){
    lock_now=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    locked=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    release_heap=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    auto thread=CreateThread(nullptr,0,heap_owner,nullptr,0,nullptr);
    if(!lock_now||!locked||!release_heap||!thread)return 1;
    auto result=DetourTransactionBegin();
    if(!result)result=DetourAttach(reinterpret_cast<PVOID*>(&trampoline),hook);
    if(result)return 2;
    SetEvent(lock_now);
    if(WaitForSingleObject(locked,3000)!=WAIT_OBJECT_0)return 3;
    // From this point no CRT allocation/logging: the suspended worker owns the
    // process heap. Both thread-record allocation and commit cleanup must work.
    result=DetourUpdateThread(thread);
    if(!result)result=DetourTransactionCommit();else DetourTransactionAbort();
    SetEvent(release_heap);
    if(WaitForSingleObject(thread,3000)!=WAIT_OBJECT_0)return 4;
    DWORD thread_result=1;GetExitCodeThread(thread,&thread_result);
    if(result||thread_result)return 5;
    const int answer=original(1);
    if(answer!=235)return 6;
    if(DetourTransactionBegin()||DetourDetach(reinterpret_cast<PVOID*>(&trampoline),hook)||DetourTransactionCommit())return 7;
    CloseHandle(thread);CloseHandle(lock_now);CloseHandle(locked);CloseHandle(release_heap);
    std::cout << "Suspended process-heap owner: transaction allocation and cleanup completed\n";
}
