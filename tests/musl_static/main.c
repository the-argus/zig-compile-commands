#include <stdio.h>

#ifndef __arm__
#warning "wrong compile_commands.json"
#endif

int main() {
  printf("hello from static musl on arm\n");
  return 0;
}
