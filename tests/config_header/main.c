#include "lib.h"

int main() {
#ifdef LIB_USE_VULKAN
  return lib_vulkan_only_function(100, 13);
#else
#warning "wrong compile_commands.json"
#endif
}
