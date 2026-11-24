#include "CHello.h"

#include <stdio.h>
#include <windows.h>

int32_t chello_add(int32_t a, int32_t b) {
  return a + b;
}

uint32_t chello_process_id(void) {
  return (uint32_t)GetCurrentProcessId();
}
