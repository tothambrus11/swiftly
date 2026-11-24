#ifndef SWIFTLY_CWINTRUST_H
#define SWIFTLY_CWINTRUST_H

#include <wchar.h>

// The WinSDK module doesn't cover WinTrust (wintrust.h/softpub.h), and WINTRUST_ACTION_GENERIC_VERIFY_V2
// is an initializer macro Swift can't import, so the Authenticode check is a small C function.
//
// Verifies the Authenticode signature of the file at `path`: the file must be signed, unmodified,
// and signed with a certificate that chains to a root the system trusts. On success, returns 0 and
// writes the signer's subject name (the certificate's common name) to `signer`. Otherwise returns
// the WinVerifyTrust error (an HRESULT such as TRUST_E_NOSIGNATURE).
long swiftly_verify_authenticode(const wchar_t *path, wchar_t *signer, unsigned long signerLength);

#endif
