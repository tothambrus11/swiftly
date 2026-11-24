#include "CWinTrust.h"

#include <windows.h>
#include <softpub.h>
#include <wintrust.h>

long swiftly_verify_authenticode(const wchar_t *path, wchar_t *signer, unsigned long signerLength) {
  GUID action = WINTRUST_ACTION_GENERIC_VERIFY_V2;

  WINTRUST_FILE_INFO file = {0};
  file.cbStruct = sizeof(file);
  file.pcwszFilePath = path;

  WINTRUST_DATA data = {0};
  data.cbStruct = sizeof(data);
  data.dwUIChoice = WTD_UI_NONE;
  data.fdwRevocationChecks = WTD_REVOKE_WHOLECHAIN;
  data.dwUnionChoice = WTD_CHOICE_FILE;
  data.pFile = &file;
  data.dwStateAction = WTD_STATEACTION_VERIFY;
  data.dwProvFlags = WTD_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT;

  LONG status = WinVerifyTrust(INVALID_HANDLE_VALUE, &action, &data);

  if (signer && signerLength > 0) {
    signer[0] = L'\0';
    if (status == ERROR_SUCCESS) {
      CRYPT_PROVIDER_DATA *provider = WTHelperProvDataFromStateData(data.hWVTStateData);
      CRYPT_PROVIDER_SGNR *signerInfo = provider ? WTHelperGetProvSignerFromChain(provider, 0, FALSE, 0) : NULL;
      CRYPT_PROVIDER_CERT *certificate = signerInfo ? WTHelperGetProvCertFromChain(signerInfo, 0) : NULL;
      if (certificate && certificate->pCert) {
        CertGetNameStringW(certificate->pCert, CERT_NAME_SIMPLE_DISPLAY_TYPE, 0, NULL, signer, signerLength);
      }
    }
  }

  data.dwStateAction = WTD_STATEACTION_CLOSE;
  WinVerifyTrust(INVALID_HANDLE_VALUE, &action, &data);
  return status;
}
