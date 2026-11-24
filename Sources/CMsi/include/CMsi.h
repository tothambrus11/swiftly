// The WinSDK module doesn't cover Windows Installer (msi.h), the cabinet decompressor (fdi.h; it
// has only the compressor, fci.h) or CNG's hashing (bcrypt.h), so this target brings in the SDK's
// headers.
// Include WinSock2.h before them, not windows.h. HWND comes from windef.h, which no WinSDK submodule
// lists, so it ends up in WinSock2, the first submodule (WinSock2.h includes windows.h). Including
// windows.h here doesn't help: clang skips windef.h because the WinSDK module already holds it.
#include <WinSock2.h>
#include <Msi.h>
#include <fdi.h>
#include <bcrypt.h>
