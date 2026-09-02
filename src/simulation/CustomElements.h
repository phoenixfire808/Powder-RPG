#pragma once
#include "common/String.h"

// Registers the property-only custom elements described by
// scripts/pbx-custom-elements.json into free element slots, allocating ids in
// file order exactly like Lua elements.allocate (255 downwards). Kinds other
// than inert/conductor get the same static definition with no Update, so ids
// stay in step with the live game; their behaviour is not reproduced.
// Names that already exist as built-in elements are skipped with a warning.
// Returns the number of elements registered; throws std::runtime_error.
int LoadCustomElements(ByteString path);
