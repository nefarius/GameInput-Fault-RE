#pragma once
#include "protocol.hpp"
#include <Windows.h>
namespace gameinput::probe {
// Setup only: exact canonical image/module pairing, x64 PE and file metadata.
DWORD identify(abi::Shared& shared) noexcept;
}
