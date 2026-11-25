#import "Runtime.h"
#include "include/cef_application_mac.h"
#include "include/cef_api_hash.h"
#include "include/capi/cef_app_capi.h"
#include "include/capi/cef_browser_capi.h"
#include "include/capi/cef_client_capi.h"
#include "include/capi/cef_cookie_capi.h"
#include "include/wrapper/cef_library_loader.h"
#include <atomic>
#include <vector>
#include <limits.h>

template<class T> struct NativeRef {
  T api{};
  std::atomic<int> count{1};
  __weak ORNativeBrowser *owner;
  NativeRef() {
    api.base.size=sizeof(T);
    api.base.add_ref=[](cef_base_ref_counted_t* p){++reinterpret_cast<NativeRef*>(p)->count;};
    api.base.release=[](cef_base_ref_counted_t* p)->int{auto r=reinterpret_cast<NativeRef*>(p);if(--r->count==0){delete r;return 1;}return 0;};
    api.base.has_one_ref=[](cef_base_ref_counted_t* p)->int{return reinterpret_cast<NativeRef*>(p)->count==1;};
    api.base.has_at_least_one_ref=[](cef_base_ref_counted_t* p)->int{return reinterpret_cast<NativeRef*>(p)->count>0;};
  }
};
static void CefText(NSString* text,cef_string_t* value){cef_string_utf8_to_utf16(text.UTF8String,strlen(text.UTF8String),value);}
static NSString* NativeText(const cef_string_t* text){return text&&text->str?[[NSString alloc]initWithCharacters:(const unichar*)text->str length:text->length]:@"";}
@interface ORChromiumApplication : NSApplication<CefAppProtocol>
@property BOOL handlingSendEvent;
@end
static void (^terminationBlock)(void);
@implementation ORChromiumApplication
- (BOOL)isHandlingSendEvent{return _handlingSendEvent;}
- (void)sendEvent:(NSEvent*)event{BOOL old=_handlingSendEvent;_handlingSendEvent=YES;[super sendEvent:event];_handlingSendEvent=old;}
- (void)terminate:(id)sender{if(terminationBlock)terminationBlock();else [super terminate:sender];}
@end
static BOOL running=NO;
static NSTimer* pump;
static BOOL pumping=NO;
static BOOL pumpAgain=NO;
static void ScheduleWork(int64_t delay);
static void RunWork(){
  if(!running)return;
  if(pumping){pumpAgain=YES;return;}
  pumping=YES;pumpAgain=NO;
  cef_do_message_loop_work();
  pumping=NO;
  if(pumpAgain)ScheduleWork(0);
  else if(!pump)ScheduleWork(33);
}
static void ScheduleWork(int64_t delay){
  dispatch_async(dispatch_get_main_queue(),^{
    if(!running)return;
    [pump invalidate];pump=nil;
    // One-shot, reentrancy-safe pump, including native event-tracking modes.
    pump=[NSTimer timerWithTimeInterval:std::max<int64_t>(1,std::min<int64_t>(33,delay))/1000.0
      repeats:NO block:^(NSTimer*){pump=nil;RunWork();}];
    [[NSRunLoop mainRunLoop]addTimer:pump forMode:NSRunLoopCommonModes];
  });
}
static NSString* profilePath;
static NSMutableSet<ORNativeBrowser*>* browsers;
// Chromium retains the command-line storage beyond CefInitialize.
static std::vector<char*> chromiumArguments;
@interface ORNativeBrowser () {
  cef_browser_t* _browser;
  NativeRef<cef_life_span_handler_t>* _life;
  NSPanel* _parking;
  BOOL _closing;
}
@property(nonatomic,readwrite) NSView* view;
@property(nonatomic,readwrite) BOOL closed;
- (nullable instancetype)initWithIdentifier:(NSString*)identifier;
- (void)browserDidClose;
- (void)destroyNativeView;
- (cef_life_span_handler_t*)lifeHandler;
@end
@implementation ORNativeBrowser
- (instancetype)initWithIdentifier:(NSString*)identifier {
  if(!(self=[super init]))return nil;
  _parking=[[NSPanel alloc]initWithContentRect:NSMakeRect(-30000,-30000,1000,700)
    styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
  _parking.releasedWhenClosed=NO;
  _parking.hidesOnDeactivate=NO;
  _view=[[NSView alloc]initWithFrame:NSMakeRect(0,0,1000,700)];
  [_parking.contentView addSubview:_view];
  _life=new NativeRef<cef_life_span_handler_t>();_life->owner=self;
  _life->api.on_before_close=[](cef_life_span_handler_t* handler,cef_browser_t*){
    ORNativeBrowser* owner=reinterpret_cast<NativeRef<cef_life_span_handler_t>*>(handler)->owner;
    [owner browserDidClose];
  };
  _life->api.do_close=[](cef_life_span_handler_t* handler,cef_browser_t*)->int{
    ORNativeBrowser* owner=reinterpret_cast<NativeRef<cef_life_span_handler_t>*>(handler)->owner;
    dispatch_async(dispatch_get_main_queue(),^{[owner destroyNativeView];});
    return 1; // Tear down the child hierarchy, never performClose on Orvlet.
  };
  _life->api.on_before_popup=[](cef_life_span_handler_t*,cef_browser_t* browser,cef_frame_t*,int,
      const cef_string_t* url,const cef_string_t*,cef_window_open_disposition_t,int gesture,
      const cef_popup_features_t*,cef_window_info_t*,cef_client_t**,cef_browser_settings_t*,cef_dictionary_value_t**,int*)->int{
    NSString* target=NativeText(url);
    if(gesture&&([target hasPrefix:@"https://"]||[target hasPrefix:@"http://"]||[target hasPrefix:@"chrome-extension://"])){
      auto frame=browser->get_main_frame(browser);frame->load_url(frame,url);frame->base.release(&frame->base);
    }
    return 1; // Background pages never create external browser windows.
  };
  auto client=new NativeRef<cef_client_t>();client->owner=self;
  client->api.get_life_span_handler=[](cef_client_t* value){
    return [reinterpret_cast<NativeRef<cef_client_t>*>(value)->owner lifeHandler];
  };
  client->api.get_jsdialog_handler=[](cef_client_t*)->cef_jsdialog_handler_t*{
    auto handler=new NativeRef<cef_jsdialog_handler_t>();
    handler->api.on_jsdialog=[](cef_jsdialog_handler_t*,cef_browser_t*,const cef_string_t*,cef_jsdialog_type_t,
      const cef_string_t*,const cef_string_t*,cef_jsdialog_callback_t*,int* suppress)->int{*suppress=1;return 0;};
    handler->api.on_before_unload_dialog=[](cef_jsdialog_handler_t*,cef_browser_t*,const cef_string_t*,int,
      cef_jsdialog_callback_t* callback)->int{callback->cont(callback,1,nullptr);return 1;};
    return &handler->api;
  };
  cef_window_info_t window{};window.size=sizeof(window);window.parent_view=(__bridge void*)_view;
  window.bounds={0,0,1000,700};
  cef_browser_settings_t settings{};settings.size=sizeof(settings);
  cef_string_t url{};CefText([@"about:blank#orvlet-" stringByAppendingString:identifier],&url);
  _browser=cef_browser_host_create_browser_sync(&window,&client->api,&url,&settings,nullptr,nullptr);
  // CEF's CToCpp wrapper adopts the incoming client reference. Releasing it
  // here would leave Chromium with a dangling callback table.
  cef_string_clear(&url);
  if(!_browser)return nil;
  auto host=_browser->get_host(_browser);
  NSView* native=(__bridge NSView*)host->get_window_handle(host);
  native.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
  host->base.release(&host->base);
  // An owned nonactivating parking panel stays outside every desktop display.
  // Moving this view into Orvlet gives the user the same native renderer.
  [_parking orderBack:nil];
  return self;
}
- (cef_life_span_handler_t*)lifeHandler{_life->api.base.add_ref(&_life->api.base);return &_life->api;}
- (void)park {
  if(_closed)return;
  if(_view.superview!=_parking.contentView){[_view removeFromSuperview];[_parking.contentView addSubview:_view];}
}
- (void)close {
  if(_closing||_closed||!_browser)return;
  _closing=YES;
  [self park]; // CEF may close its top-level window: never let that be the Orvlet shell.
  auto host=_browser->get_host(_browser);host->close_browser(host,1);host->base.release(&host->base);
}
- (void)focusRenderer {
  if(_closing||_closed||!_browser)return;
  // CEF changes renderer activation and the local first responder only. It
  // does not make an NSWindow key or activate the application.
  auto host=_browser->get_host(_browser);host->set_focus(host,1);host->base.release(&host->base);
}
- (void)browserDidClose {
  _closed=YES;
  [_parking orderOut:nil];
  [_view removeFromSuperview];
  if(_browser){_browser->base.release(&_browser->base);_browser=nullptr;}
  [browsers removeObject:self];
}
- (void)destroyNativeView {
  for(NSView* child in _view.subviews.copy)[child removeFromSuperview];
  [_view removeFromSuperview];
  [_parking orderOut:nil];
  _parking.contentView=nil;
}
- (void)dealloc{if(_life)_life->api.base.release(&_life->api.base);}
@end
struct CookieCompletion {
  cef_completion_callback_t api{};std::atomic<int> count{1};void (^completion)(void);
  CookieCompletion(void (^block)(void)):completion([block copy]){
    api.base.size=sizeof(api);
    api.base.add_ref=[](cef_base_ref_counted_t* p){++reinterpret_cast<CookieCompletion*>(p)->count;};
    api.base.release=[](cef_base_ref_counted_t* p)->int{auto r=reinterpret_cast<CookieCompletion*>(p);if(--r->count==0){delete r;return 1;}return 0;};
    api.base.has_one_ref=[](cef_base_ref_counted_t* p)->int{return reinterpret_cast<CookieCompletion*>(p)->count==1;};
    api.base.has_at_least_one_ref=[](cef_base_ref_counted_t* p)->int{return reinterpret_cast<CookieCompletion*>(p)->count>0;};
    api.on_complete=[](cef_completion_callback_t* p){auto block=reinterpret_cast<CookieCompletion*>(p)->completion;dispatch_async(dispatch_get_main_queue(),block);};
  }
};
@implementation ORNativeChromium
+ (void)prepareApplication{[ORChromiumApplication sharedApplication];}
+ (void)setTermination:(void (^)(void))termination{terminationBlock=[termination copy];}
+ (BOOL)isRunning{return running;}
+ (BOOL)startWithProfile:(NSString*)profile extensions:(NSString*)extensionRoot guest:(BOOL)guest port:(int)port error:(NSError**)error {
  char canonical[PATH_MAX];
  if(realpath(profile.fileSystemRepresentation,canonical))profile=[NSString stringWithUTF8String:canonical];
  if(running){if([profilePath isEqual:profile])return YES; if(error)*error=[NSError errorWithDomain:@"OrvletChromium" code:2 userInfo:@{NSLocalizedDescriptionKey:@"The native browser is already using another profile."}];return NO;}
  NSString* frameworks=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents/Frameworks"];
  NSString* library=[frameworks stringByAppendingPathComponent:@"Chromium Embedded Framework.framework/Chromium Embedded Framework"];
  if(!cef_load_library(library.UTF8String)){
    if(error)*error=[NSError errorWithDomain:@"OrvletChromium" code:3 userInfo:@{NSLocalizedDescriptionKey:@"The native Chromium framework is missing or could not be loaded."}];
    return NO;
  }
  cef_api_hash(CEF_API_VERSION,0);
  NSMutableArray<NSString*>* arguments=[NSMutableArray arrayWithArray:NSProcessInfo.processInfo.arguments];
  [arguments addObjectsFromArray:@[@"--no-first-run",@"--no-default-browser-check",@"--disable-background-networking",@"--disable-sync",@"--autoplay-policy=no-user-gesture-required"]];
  // Chromium writes generated ruleset caches beside unpacked extensions. Keep
  // them in the owned profile so the signed application bundle stays immutable.
  NSData* index=[NSData dataWithContentsOfFile:[extensionRoot stringByAppendingPathComponent:@"extensions.json"]];
  id entries=index?[NSJSONSerialization JSONObjectWithData:index options:0 error:nil]:nil;
  NSMutableArray<NSString*>* extensions=[NSMutableArray new];
  if([entries isKindOfClass:NSArray.class])for(id entry in entries){
    if(![entry isKindOfClass:NSDictionary.class]||[entry[@"digest"] isEqual:@"bundled"]||![entry[@"enabled"] boolValue])continue;
    NSString* identifier=entry[@"id"];
    NSCharacterSet* allowed=[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-"];
    if(![identifier isKindOfClass:NSString.class]||identifier.length==0||identifier.length>80||[identifier rangeOfCharacterFromSet:allowed.invertedSet].location!=NSNotFound)continue;
    NSString* directory=[[extensionRoot stringByAppendingPathComponent:@"Extensions"] stringByAppendingPathComponent:identifier];
    if([[NSFileManager defaultManager]fileExistsAtPath:[directory stringByAppendingPathComponent:@"manifest.json"]])[extensions addObject:directory];
  }
  if(extensions.count)[arguments addObject:[@"--load-extension=" stringByAppendingString:[extensions componentsJoinedByString:@","]]];
  if([arguments containsObject:@"--background-checks"]||[arguments containsObject:@"--native-browser-check"]){
    [arguments addObject:@"--mute-audio"];
    // Isolated synthetic-cookie checks must never request access to the user's
    // macOS Keychain. Production profiles keep Chromium's normal encryption.
#if DEBUG
    NSString* temp=NSTemporaryDirectory().stringByResolvingSymlinksInPath;
    if(!guest && [arguments containsObject:@"--native-browser-check"] &&
       [extensionRoot.lastPathComponent hasPrefix:@"orvlet-native-check-"] &&
       [extensionRoot.stringByDeletingLastPathComponent.stringByResolvingSymlinksInPath isEqual:temp.stringByStandardizingPath])
      [arguments addObject:@"--use-mock-keychain"];
#endif
    [arguments addObject:@"--disable-features=DialMediaRouteProvider"];
  }
  // Guest pages use in-memory site storage and a fresh runtime directory.
  // Never use this switch with a user's saved Chromium profile.
  if(guest)[arguments addObject:@"--use-mock-keychain"];
  for(NSString* argument in arguments)chromiumArguments.push_back(strdup(argument.UTF8String));
  cef_main_args_t args{(int)chromiumArguments.size(),chromiumArguments.data()};
  cef_settings_t settings{};settings.size=sizeof(settings);settings.external_message_pump=1;
  CefText(profile,&settings.root_cache_path);
  if(!guest){
    settings.persist_session_cookies=1;
    CefText([profile stringByAppendingPathComponent:@"Default"],&settings.cache_path);
  }
  CefText([frameworks stringByAppendingPathComponent:@"Orvlet Helper.app/Contents/MacOS/Orvlet Helper"],&settings.browser_subprocess_path);
  CefText([profile stringByAppendingPathComponent:@"chromium.log"],&settings.log_file);
  settings.remote_debugging_port=port;
  auto application=new NativeRef<cef_app_t>();
  application->api.get_browser_process_handler=[](cef_app_t*)->cef_browser_process_handler_t*{
    auto handler=new NativeRef<cef_browser_process_handler_t>();
    handler->api.on_schedule_message_pump_work=[](cef_browser_process_handler_t*,int64_t delay){ScheduleWork(delay);};
    return &handler->api;
  };
  BOOL initialized=cef_initialize(&args,&settings,&application->api,nullptr);
  cef_string_clear(&settings.root_cache_path);cef_string_clear(&settings.cache_path);
  cef_string_clear(&settings.browser_subprocess_path);cef_string_clear(&settings.log_file);
  if(!initialized){if(error)*error=[NSError errorWithDomain:@"OrvletChromium" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Could not initialize the native browser."}];return NO;}
  running=YES;profilePath=[profile copy];browsers=[NSMutableSet new];
  ScheduleWork(0);
  return YES;
}
+ (ORNativeBrowser*)createBrowser:(NSString*)identifier {
  if(!running)return nil;
  ORNativeBrowser* browser=[[ORNativeBrowser alloc]initWithIdentifier:identifier];
  if(browser)[browsers addObject:browser];return browser;
}
+ (void)closeBrowsers{for(ORNativeBrowser* browser in browsers.allObjects)[browser close];}
+ (NSUInteger)browserCount{return browsers.count;}
+ (void)flushCookies:(void (^)(void))completion {
  if(!running){completion();return;}
  auto manager=cef_cookie_manager_get_global_manager(nullptr);
  auto callback=new CookieCompletion(completion);
  if(!manager->flush_store(manager,&callback->api))completion();
  // flush_store likewise adopts the callback reference, even on failure.
  manager->base.release(&manager->base);
}
+ (void)shutdown {
  if(!running)return;
  [self closeBrowsers];
  NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:10];
  while(browsers.count&&deadline.timeIntervalSinceNow>0)
    [[NSRunLoop mainRunLoop]runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  if(browsers.count)return; // Never destroy a runtime with live native views.
  [pump invalidate];pump=nil;cef_shutdown();running=NO;
  for(char* argument:chromiumArguments)free(argument);chromiumArguments.clear();
}
@end
