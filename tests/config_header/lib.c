#include "lib.h"

int lib_add(int a, int b) { return a + b; }

#ifdef LIB_USE_VULKAN
int lib_vulkan_only_function(int a, int b) { return a - b; }
#endif
