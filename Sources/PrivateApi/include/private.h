#ifndef private_header_h
#define private_header_h

#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>

// ============================================================================
// Existing AeroSpace private API
// ============================================================================

AXError _AXUIElementGetWindow(AXUIElementRef element, uint32_t *identifier);

// ============================================================================
// SkyLight Private API for faster window management
// Requires SIP to be partially disabled
// ============================================================================

// Connection management
extern int SLSMainConnectionID(void);
extern CGError SLSNewConnection(int zero, int *cid);
extern CGError SLSReleaseConnection(int cid);

// Process management - key for fast focus switching
extern OSStatus _SLPSGetFrontProcess(ProcessSerialNumber *psn);
extern CGError _SLPSSetFrontProcessWithOptions(ProcessSerialNumber *psn, uint32_t wid, uint32_t mode);
extern CGError SLPSPostEventRecordTo(ProcessSerialNumber *psn, uint8_t *bytes);
extern CGError SLSGetConnectionPSN(int cid, ProcessSerialNumber *psn);
extern CGError SLSConnectionGetPID(int cid, pid_t *pid);
extern CGError SLSGetConnectionIDForPSN(int cid, ProcessSerialNumber *psn, int *psn_cid);
extern CGError SLSGetWindowOwner(int cid, uint32_t wid, int *wcid);

// Window operations
extern CGError SLSGetWindowBounds(int cid, uint32_t wid, CGRect *frame);
extern CGError SLSSetWindowShape(int cid, uint32_t wid, float x_offset, float y_offset, CGPathRef shape);
extern CGError SLSGetWindowLevel(int cid, uint32_t wid, int *level);
extern CGError SLSSetWindowLevel(int cid, uint32_t wid, int level);
extern CGError SLSOrderWindow(int cid, uint32_t wid, int mode, uint32_t rel_wid);
extern CGError SLSMoveWindow(int cid, uint32_t wid, CGPoint *point);
extern CGError SLSSetWindowAlpha(int cid, uint32_t wid, float alpha);
extern CGError SLSGetWindowAlpha(int cid, uint32_t wid, float *alpha);
extern CGError SLSWindowIsOrderedIn(int cid, uint32_t wid, uint8_t *value);

// Window resize - CoreGraphics private API
extern CGError CGSSetWindowTransform(int cid, uint32_t wid, CGAffineTransform transform);
extern CGError CGSGetWindowTransform(int cid, uint32_t wid, CGAffineTransform *transform);

// Move window with group (more efficient for grouped windows)
extern CGError SLSMoveWindowWithGroup(int cid, uint32_t wid, CGPoint *point);

// Window tags for special behaviors
extern CGError SLSSetWindowTags(int cid, uint32_t wid, uint64_t *tags, int tag_size);
extern CGError SLSClearWindowTags(int cid, uint32_t wid, uint64_t *tags, int tag_size);

// Transaction API - batch multiple window operations for better performance
extern CFTypeRef SLSTransactionCreate(int cid);
extern CGError SLSTransactionCommit(CFTypeRef transaction, int synchronous);
extern CGError SLSTransactionOrderWindow(CFTypeRef transaction, uint32_t wid, int order, uint32_t rel_wid);
extern CGError SLSTransactionSetWindowAlpha(CFTypeRef transaction, uint32_t wid, float alpha);
extern CGError SLSTransactionSetWindowSystemAlpha(CFTypeRef transaction, uint32_t wid, float alpha);

// Space management
extern CFArrayRef SLSCopyManagedDisplays(int cid);
extern uint64_t SLSManagedDisplayGetCurrentSpace(int cid, CFStringRef uuid);
extern CFStringRef SLSCopyManagedDisplayForWindow(int cid, uint32_t wid);
extern CFArrayRef SLSCopySpacesForWindows(int cid, int selector, CFArrayRef window_list);
extern void SLSMoveWindowsToManagedSpace(int cid, CFArrayRef window_list, uint64_t sid);

// Display update control - reduce flickering
extern CGError SLSDisableUpdate(int cid);
extern CGError SLSReenableUpdate(int cid);

// Window query
extern CFArrayRef SLSCopyWindowsWithOptionsAndTags(int cid, uint32_t owner, CFArrayRef spaces, uint32_t options, uint64_t *set_tags, uint64_t *clear_tags);

// Constants for _SLPSSetFrontProcessWithOptions
#define kCPSNoWindows 0x0
#define kCPSUserGenerated 0x200
#define kCPSNoFocus 0x400

#endif
