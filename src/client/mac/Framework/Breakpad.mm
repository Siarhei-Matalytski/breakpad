// Copyright (c) 2006, Google Inc.
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//     * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//     * Neither the name of Google Inc. nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

#define VERBOSE 0

#if VERBOSE
  static bool gDebugLog = true;
#else
  static bool gDebugLog = false;
#endif

#define DEBUGLOG if (gDebugLog) fprintf
#define IGNORE_DEBUGGER "BREAKPAD_IGNORE_DEBUGGER"

#import "client/mac/Framework/Breakpad.h"

#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <sys/sysctl.h>

#import "client/mac/handler/exception_handler.h"
#import "client/mac/Framework/Breakpad.h"
#import "client/mac/handler/protected_memory_allocator.h"
#import "common/mac/MachIPC.h"
#import "common/mac/SimpleStringDictionary.h"

using google_breakpad::KeyValueEntry;
using google_breakpad::MachPortSender;
using google_breakpad::MachReceiveMessage;
using google_breakpad::MachSendMessage;
using google_breakpad::ReceivePort;
using google_breakpad::SimpleStringDictionary;
using google_breakpad::SimpleStringDictionaryIterator;

//=============================================================================
// We want any memory allocations which are used by breakpad during the
// exception handling process (after a crash has happened) to be read-only
// to prevent them from being smashed before a crash occurs.  Unfortunately
// we cannot protect against smashes to our exception handling thread's
// stack.
//
// NOTE: Any memory allocations which are not used during the exception
// handling process may be allocated in the normal ways.
//
// The ProtectedMemoryAllocator class provides an Allocate() method which
// we'll using in conjunction with placement operator new() to control
// allocation of C++ objects.  Note that we don't use operator delete()
// but instead call the objects destructor directly:  object->~ClassName();
//
ProtectedMemoryAllocator *gMasterAllocator = NULL;
ProtectedMemoryAllocator *gKeyValueAllocator = NULL;
ProtectedMemoryAllocator *gBreakpadAllocator = NULL;

// Mutex for thread-safe access to the key/value dictionary used by breakpad.
// It's a global instead of an instance variable of Breakpad
// since it can't live in a protected memory area.
pthread_mutex_t gDictionaryMutex;

//=============================================================================
// Stack-based object for thread-safe access to a memory-protected region.
// It's assumed that normally the memory block (allocated by the allocator)
// is protected (read-only).  Creating a stack-based instance of
// ProtectedMemoryLocker will unprotect this block after taking the lock.
// Its destructor will first re-protect the memory then release the lock.
class ProtectedMemoryLocker {
public:
  // allocator may be NULL, in which case no Protect() or Unprotect() calls
  // will be made, but a lock will still be taken
  ProtectedMemoryLocker(pthread_mutex_t *mutex,
                        ProtectedMemoryAllocator *allocator)
  : mutex_(mutex), allocator_(allocator) {
    // Lock the mutex
    assert(pthread_mutex_lock(mutex_) == 0);

    // Unprotect the memory
    if (allocator_ ) {
      allocator_->Unprotect();
    }
  }

  ~ProtectedMemoryLocker() {
    // First protect the memory
    if (allocator_) {
      allocator_->Protect();
    }

    // Then unlock the mutex
    assert(pthread_mutex_unlock(mutex_) == 0);
  };

private:
  //  Keep anybody from ever creating one of these things not on the stack.
  ProtectedMemoryLocker() { }
  ProtectedMemoryLocker(const ProtectedMemoryLocker&);
  ProtectedMemoryLocker & operator=(ProtectedMemoryLocker&);

  pthread_mutex_t           *mutex_;
  ProtectedMemoryAllocator  *allocator_;
};

//=============================================================================
class Breakpad {
 public:
  // factory method
  static Breakpad *Create(NSDictionary *parameters) {
    // Allocate from our special allocation pool
    Breakpad *breakpad =
      new (gBreakpadAllocator->Allocate(sizeof(Breakpad)))
        Breakpad();

    if (!breakpad)
      return NULL;

    if (!breakpad->Initialize(parameters)) {
      // Don't use operator delete() here since we allocated from special pool
      breakpad->~Breakpad();
      return NULL;
    }

    return breakpad;
  }

  ~Breakpad();

  void SetKeyValue(NSString *key, NSString *value);
  NSString *KeyValue(NSString *key);
  void RemoveKeyValue(NSString *key);

  void GenerateAndSendReport();

 private:
  Breakpad()
    : handler_(NULL),
      config_params_(NULL),
      send_and_exit_(true) {
  }

  bool Initialize(NSDictionary *parameters);

  bool ExtractParameters(NSDictionary *parameters);

  // Dispatches to HandleException()
  static bool ExceptionHandlerDirectCallback(void *context,
                                             int exception_type,
                                             int exception_code,
                                             int exception_subcode,
                                             mach_port_t crashing_thread);

  bool HandleException(int exception_type,
                       int exception_code,
                       int exception_subcode,
                       mach_port_t crashing_thread);

  // Since ExceptionHandler (w/o namespace) is defined as typedef in OSX's
  // MachineExceptions.h, we have to explicitly name the handler.
  google_breakpad::ExceptionHandler *handler_; // The actual handler (STRONG)

  SimpleStringDictionary  *config_params_; // Create parameters (STRONG)

  bool                    send_and_exit_;  // Exit after sending, if true
};

#pragma mark -
#pragma mark Helper functions

//=============================================================================
// Helper functions

//=============================================================================
static BOOL IsDebuggerActive() {
  BOOL result = NO;
  NSUserDefaults *stdDefaults = [NSUserDefaults standardUserDefaults];

  // We check both defaults and the environment variable here

  BOOL ignoreDebugger = [stdDefaults boolForKey:@IGNORE_DEBUGGER];

  if (!ignoreDebugger) {
    char *ignoreDebuggerStr = getenv(IGNORE_DEBUGGER);
    ignoreDebugger = (ignoreDebuggerStr ? strtol(ignoreDebuggerStr, NULL, 10) : 0) != 0;
  }

  if (!ignoreDebugger) {
    pid_t pid = getpid();
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    int mibSize = sizeof(mib) / sizeof(int);
    size_t actualSize;

    if (sysctl(mib, mibSize, NULL, &actualSize, NULL, 0) == 0) {
      struct kinfo_proc *info = (struct kinfo_proc *)malloc(actualSize);

      if (info) {
        // This comes from looking at the Darwin xnu Kernel
        if (sysctl(mib, mibSize, info, &actualSize, NULL, 0) == 0)
          result = (info->kp_proc.p_flag & P_TRACED) ? YES : NO;

        free(info);
      }
    }
  }

  return result;
}

//=============================================================================
bool Breakpad::ExceptionHandlerDirectCallback(void *context,
                                                    int exception_type,
                                                    int exception_code,
                                                    int exception_subcode,
                                                    mach_port_t crashing_thread) {
  Breakpad *breakpad = (Breakpad *)context;

  // If our context is damaged or something, just return false to indicate that
  // the handler should continue without us.
  if (!breakpad)
    return false;

  return breakpad->HandleException( exception_type,
                                    exception_code,
                                    exception_subcode,
                                    crashing_thread);
}

//=============================================================================
#pragma mark -

#include <dlfcn.h>

//=============================================================================
// Returns the pathname to the Resources directory for this version of
// Breakpad which we are now running.
//
// Don't make the function static, since _dyld_lookup_and_bind_fully needs a
// simple non-static C name
//
extern "C" {
NSString * GetResourcePath();
NSString * GetResourcePath() {
  NSString *resourcePath = nil;

  // If there are multiple breakpads installed then calling bundleWithIdentifier
  // will not work properly, so only use that as a backup plan.
  // We want to find the bundle containing the code where this function lives
  // and work from there
  //

  // Get the pathname to the code which contains this function
  Dl_info info;
  if (dladdr((const void*)GetResourcePath, &info) != 0) {
    NSFileManager *filemgr = [NSFileManager defaultManager];
    NSString *filePath =
        [filemgr stringWithFileSystemRepresentation:info.dli_fname
                                             length:strlen(info.dli_fname)];
    NSString *bundlePath = [filePath stringByDeletingLastPathComponent];
    // The "Resources" directory should be in the same directory as the
    // executable code, since that's how the Breakpad framework is built.
    resourcePath = [bundlePath stringByAppendingPathComponent:@"Resources/"];
  } else {
    DEBUGLOG(stderr, "Could not find GetResourcePath\n");
    // fallback plan
    NSBundle *bundle =
        [NSBundle bundleWithIdentifier:@"com.Google.BreakpadFramework"];
    resourcePath = [bundle resourcePath];
  }

  return resourcePath;
}
}  // extern "C"

//=============================================================================
bool Breakpad::Initialize(NSDictionary *parameters) {
  // Initialize
  config_params_ = NULL;
  handler_ = NULL;

  // Check for debugger
  if (IsDebuggerActive()) {
    DEBUGLOG(stderr, "Debugger is active:  Not installing handler\n");
    return true;
  }

  // Gather any user specified parameters
  if (!ExtractParameters(parameters)) {
    return false;
  }

  // Create the handler (allocating it in our special protected pool)
  handler_ =
      new (gBreakpadAllocator->Allocate(
          sizeof(google_breakpad::ExceptionHandler)))
          google_breakpad::ExceptionHandler(
             config_params_->GetValueForKey("PATH"), NULL, NULL, NULL, true, NULL);
  return true;
}

//=============================================================================
Breakpad::~Breakpad() {
  // Note that we don't use operator delete() on these pointers,
  // since they were allocated by ProtectedMemoryAllocator objects.
  //
  if (config_params_) {
    config_params_->~SimpleStringDictionary();
  }

  if (handler_)
    handler_->~ExceptionHandler();
}

//=============================================================================
bool Breakpad::ExtractParameters(NSDictionary *parameters) {
	
  if (![parameters objectForKey:@"PATH"])
	  return false;

  config_params_ =
      new (gKeyValueAllocator->Allocate(sizeof(SimpleStringDictionary)) )
        SimpleStringDictionary();

  config_params_->SetKeyValue("PATH", [[parameters objectForKey:@"PATH"] UTF8String]);
  return true;
}

//=============================================================================
bool Breakpad::HandleException(int exception_type,
                               int exception_code,
                               int exception_subcode,
                               mach_port_t crashing_thread) {
  DEBUGLOG(stderr, "Breakpad: an exception occurred\n");

  // We need to reset the memory protections to be read/write,
  // since LaunchOnDemand() requires changing state.
  gBreakpadAllocator->Unprotect();
  // Configure the server to launch when we message the service port.
  // The reason we do this here, rather than at startup, is that we
  // can leak a bootstrap service entry if this method is called and
  // there never ends up being a crash.
  //inspector_.LaunchOnDemand();
  gBreakpadAllocator->Protect();

   // If we don't want any forwarding, return true here to indicate that we've
  // processed things as much as we want.
  if (send_and_exit_) return true;

  return false;
}

//=============================================================================
//=============================================================================

#pragma mark -
#pragma mark Public API

//=============================================================================
BreakpadRef BreakpadCreate(NSDictionary *parameters) {
  try {
    // This is confusing.  Our two main allocators for breakpad memory are:
    //    - gKeyValueAllocator for the key/value memory
    //    - gBreakpadAllocator for the Breakpad, ExceptionHandler, and other
    //      breakpad allocations which are accessed at exception handling time.
    //
    // But in order to avoid these two allocators themselves from being smashed,
    // we'll protect them as well by allocating them with gMasterAllocator.
    //
    // gMasterAllocator itself will NOT be protected, but this doesn't matter,
    // since once it does its allocations and locks the memory, smashes to itself
    // don't affect anything we care about.
    gMasterAllocator =
        new ProtectedMemoryAllocator(sizeof(ProtectedMemoryAllocator) * 2);

    gKeyValueAllocator =
        new (gMasterAllocator->Allocate(sizeof(ProtectedMemoryAllocator)))
            ProtectedMemoryAllocator(sizeof(SimpleStringDictionary));

    // Create a mutex for use in accessing the SimpleStringDictionary
    int mutexResult = pthread_mutex_init(&gDictionaryMutex, NULL);
    if (mutexResult == 0) {

      // With the current compiler, gBreakpadAllocator is allocating 1444 bytes.
      // Let's round up to the nearest page size.
      //
      int breakpad_pool_size = 4096;

      /*
       sizeof(Breakpad)
       + sizeof(google_breakpad::ExceptionHandler)
       + sizeof( STUFF ALLOCATED INSIDE ExceptionHandler )
       */

      gBreakpadAllocator =
          new (gMasterAllocator->Allocate(sizeof(ProtectedMemoryAllocator)))
              ProtectedMemoryAllocator(breakpad_pool_size);

      // Stack-based autorelease pool for Breakpad::Create() obj-c code.
      NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
      Breakpad *breakpad = Breakpad::Create(parameters);

      if (breakpad) {
        // Make read-only to protect against memory smashers
        gMasterAllocator->Protect();
        gKeyValueAllocator->Protect();
        gBreakpadAllocator->Protect();
        // Can uncomment this line to figure out how much space was actually
        // allocated using this allocator
        //     printf("gBreakpadAllocator allocated size = %d\n",
        //         gBreakpadAllocator->GetAllocatedSize() );
        [pool release];
        return (BreakpadRef)breakpad;
      }

      [pool release];
    }
  } catch(...) {    // don't let exceptions leave this C API
    fprintf(stderr, "BreakpadCreate() : error\n");
  }

  if (gKeyValueAllocator) {
    gKeyValueAllocator->~ProtectedMemoryAllocator();
    gKeyValueAllocator = NULL;
  }

  if (gBreakpadAllocator) {
    gBreakpadAllocator->~ProtectedMemoryAllocator();
    gBreakpadAllocator = NULL;
  }

  delete gMasterAllocator;
  gMasterAllocator = NULL;

  return NULL;
}

//=============================================================================
void BreakpadRelease(BreakpadRef ref) {
  try {
    Breakpad *breakpad = (Breakpad *)ref;

    if (gMasterAllocator) {
      gMasterAllocator->Unprotect();
      gKeyValueAllocator->Unprotect();
      gBreakpadAllocator->Unprotect();

      breakpad->~Breakpad();

      // Unfortunately, it's not possible to deallocate this stuff
      // because the exception handling thread is still finishing up
      // asynchronously at this point...  OK, it could be done with
      // locks, etc.  But since BreakpadRelease() should usually only
      // be called right before the process exits, it's not worth
      // deallocating this stuff.
#if 0
      gKeyValueAllocator->~ProtectedMemoryAllocator();
      gBreakpadAllocator->~ProtectedMemoryAllocator();
      delete gMasterAllocator;

      gMasterAllocator = NULL;
      gKeyValueAllocator = NULL;
      gBreakpadAllocator = NULL;
#endif

      pthread_mutex_destroy(&gDictionaryMutex);
    }
  } catch(...) {    // don't let exceptions leave this C API
    fprintf(stderr, "BreakpadRelease() : error\n");
  }
}
