#include <SDL3/SDL.h>

#include <stdint.h>

#define TARGET_FPS (60)
#define NS_PER_SEC 1000000000ULL
#define TARGET_FRAME_NS (NS_PER_SEC / TARGET_FPS)

int frame() {
  /* do per-frame things, return 0 to quit */
  return 1;
}

int main() {
  // initialization

  // main loop
  int running = 1;
  uint64_t last_frame_end_ns = 0;
  while (running) {
    SDL_Event event = {0};

    if (SDL_WaitEvent(&event)) {
      running = frame();

      while (running && SDL_PollEvent(&event))
        running = frame();
    }

    uint64_t delta_time_ns = SDL_GetTicksNS() - last_frame_end_ns;
    if (delta_time_ns < TARGET_FRAME_NS) {
      SDL_DelayNS(TARGET_FRAME_NS - delta_time_ns);
    }
    last_frame_end_ns = SDL_GetTicksNS();
  }

  // deinitialization

  return 0;
}
