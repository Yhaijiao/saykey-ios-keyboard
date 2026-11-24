#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// Makes this process a keyboard arbiter client before UIKit decides it is
// not one. Only arbiter clients receive the system keyboard state events
// (_UIKeyboardChangedInformation) that name the app the keyboard is used in;
// Lab and the keyboard extension need them to send the user back to that
// app. Undocumented: every step is checked at runtime and does nothing when
// the class or method is missing. It must run before main, because UIKit
// reads the flag while it sets up the process.
__attribute__((constructor))
static void SayKeyEnableKeyboardArbiterClient(void) {
    Class cls = NSClassFromString(@"_UIKeyboardArbiterClient");
    if (cls == Nil) { return; }
    Method method = class_getClassMethod(cls, NSSelectorFromString(@"enabled"));
    if (method == NULL) { return; }
    char returnType[8] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    // Only replace a BOOL-returning getter taking no arguments.
    if ((returnType[0] != 'B' && returnType[0] != 'c') || method_getNumberOfArguments(method) != 2) { return; }
    IMP alwaysOn = imp_implementationWithBlock(^BOOL(id receiver) { return YES; });
    method_setImplementation(method, alwaysOn);
}
