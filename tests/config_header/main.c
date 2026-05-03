#include "lib.h"

int main() {
#ifdef LIB_USE_VULKAN
  return lib_vulkan_only_function(100, 13);
#else
  return lib_add(1, 1);
#endif
}
