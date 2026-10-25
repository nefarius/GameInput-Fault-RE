#pragma once
#include "engine.hpp"
namespace gameinput::probe {
// Setup only. Validates transferred handle without broadening its DACL.
DWORD validate_mapping(HANDLE handle) noexcept;
DWORD validate_mapping_security(HANDLE handle) noexcept;
}
