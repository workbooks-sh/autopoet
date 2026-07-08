// The app's MAIN EXECUTABLE must be a real Mach-O: with a bash script there,
// macOS resolves the app's root process to /bin/bash — a system binary TCC can
// never prompt for — so every mic/camera request by any child auto-denies.
// This launcher just exec's the real launch script; the process (and every
// child) now carries the app bundle's identity for responsibility/TCC.
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
  char exe[PATH_MAX];
  uint32_t n = sizeof(exe);
  if (_NSGetExecutablePath(exe, &n) != 0) return 1;
  char dir[PATH_MAX];
  strncpy(dir, dirname(exe), sizeof(dir) - 1);
  char script[PATH_MAX];
  snprintf(script, sizeof(script), "%s/../Resources/launch.sh", dir);
  execl("/bin/bash", "/bin/bash", script, (char *)NULL);
  perror("exec launch.sh");
  return 1;
}
