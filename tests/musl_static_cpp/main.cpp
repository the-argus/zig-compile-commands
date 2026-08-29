#include <cstdio>
#include <vector>

#ifndef __arm__
#warning "wrong compile_commands.json"
#endif

// zig manually defines _LIBCPP_VERSION and has a patched __config header so
// that clang does not define it
#ifndef _LIBCPP_VERSION
#warning "wrong compile commands: not using zig's vendored libc++"
#endif

// these are basically the same error as above, just for macros from
// __config_site
#if !_LIBCPP_HAS_MUSL_LIBC
#warning "wrong compile commands: libc++ is not configured for musl"
#endif
#if !_LIBCPP_HAS_THREADS
#warning "wrong compile commands: libc++ is configured without threads"
#endif

int main() {
  std::vector<int> values = {1, 2, 3};
  int sum = 0;
  for (int value : values) {
    sum += value;
  }
  std::printf("sum: %d\n", sum);
  return sum == 6 ? 0 : 1;
}
