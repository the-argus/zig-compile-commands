#ifndef __LIB_H__
#define __LIB_H__

#include "lib_config.h"

int lib_add(int, int);

#ifdef LIB_USE_VULKAN
int lib_vulkan_only_function(int, int);
#endif

#endif
