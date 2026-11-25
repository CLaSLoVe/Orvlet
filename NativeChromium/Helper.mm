#include "include/cef_api_hash.h"
#include "include/capi/cef_app_capi.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"
int main(int argc,char** argv){
  CefScopedSandboxContext sandbox;
  if(!sandbox.Initialize(argc,argv))return 1;
  CefScopedLibraryLoader library;
  if(!library.LoadInHelper())return 2;
  cef_api_hash(CEF_API_VERSION,0);
  cef_main_args_t args{argc,argv};
  return cef_execute_process(&args,nullptr,nullptr);
}
