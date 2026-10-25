//
//  MNDVirtualMachine.h — a Linux or macOS guest on Virtualization.framework.
//
//  Owns the VZVirtualMachine, its private dispatch queue, and the unix-socket
//  bridge that exposes guest vsock ports (sshd) to host processes.
//

#import <Foundation/Foundation.h>
#import <Virtualization/Virtualization.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const MNDVirtualMachineErrorDomain;

typedef NS_ENUM(NSInteger, MNDVirtualMachineState) {
    MNDVirtualMachineStateStopped = 0,
    MNDVirtualMachineStateStarting,
    MNDVirtualMachineStateRunning,
    MNDVirtualMachineStateStopping,
    MNDVirtualMachineStateError,
};

/// One host folder inside the guest's virtio-fs share.
@interface MNDSharedDirectory : NSObject
/// Unique within the VM; the guest sees it as a top-level directory of the share.
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSString *path;
@property (nonatomic, readonly) BOOL readOnly;
- (instancetype)initWithName:(NSString *)name path:(NSString *)path readOnly:(BOOL)readOnly NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Static description of a guest. All paths are absolute.
@interface MNDVMConfig : NSObject
@property (nonatomic, copy) NSString *diskPath;
@property (nonatomic, copy, nullable) NSString *seedISOPath;
@property (nonatomic, copy) NSString *efiVariableStorePath;
/// Linux: a VZGenericMachineIdentifier; macOS: a VZMacMachineIdentifier.
/// Made when missing.
@property (nonatomic, copy) NSString *machineIdentifierPath;
/// A macOS guest (Phase 14): Apple's boot loader and platform, from the
/// auxiliary storage and hardware model its install wrote (both must exist);
/// no EFI store and no seed. Headless: no graphics device.
@property (nonatomic) BOOL macOS;
@property (nonatomic, copy, nullable) NSString *auxiliaryStoragePath;
@property (nonatomic, copy, nullable) NSString *hardwareModelPath;
@property (nonatomic, copy, nullable) NSString *serialLogPath;
@property (nonatomic) NSUInteger cpuCount;
@property (nonatomic) uint64_t memoryBytes;
@property (nonatomic) BOOL networkEnabled;
/// "xx:xx:xx:xx:xx:xx"; generated and written back when nil.
@property (nonatomic, copy, nullable) NSString *macAddress;
/// The NIC is on a Monad network: its frames go through networkFileHandle (a
/// datagram socket to monad-netd). Without the handle the configuration is
/// refused, never replaced by Apple's NAT. Off: Apple's NAT.
@property (nonatomic) BOOL networkThroughSocket;
@property (nonatomic, strong, nullable) NSFileHandle *networkFileHandle;
/// The guest gets a virtio-fs device only when this is on. Its folder set
/// can change while the VM runs; the device itself cannot.
@property (nonatomic) BOOL runtimeSharingEnabled;
/// virtio-fs tag the guest mounts ("monad").
@property (nonatomic, copy) NSString *sharingTag;
/// Folders shared at boot; ignored unless runtimeSharingEnabled.
@property (nonatomic, copy) NSArray<MNDSharedDirectory *> *sharedDirectories;
/// A macOS guest booted into its recoveryOS (System Integrity Protection),
/// which Monad drives through its keyboard and pointer (-pressKeys:down:error:).
@property (nonatomic) BOOL recovery;
/// A macOS guest's display (its desktop, opened from Monad) with a USB
/// keyboard and a pointer; 0 wide: none (a Linux guest).
@property (nonatomic) NSUInteger displayWidth;
@property (nonatomic) NSUInteger displayHeight;
@property (nonatomic) NSUInteger displayPixelsPerInch;
/// Repair Disk's temporary VM: a USB controller, to which another VM's disk
/// is attached once this one runs (-attachDiskAtPath:completion:). macOS 15
/// and later; ignored before.
@property (nonatomic) BOOL usbDisks;
@end

@class MNDVirtualMachine;

/// A connected guest vsock stream. Owns its file descriptor until -close.
NS_SWIFT_SENDABLE
@interface MNDVsockChannel : NSObject
@property (nonatomic, readonly) int fileDescriptor;
- (void)close;
- (instancetype)init NS_UNAVAILABLE;
@end

@protocol MNDVirtualMachineDelegate <NSObject>
/// Called on the main queue.
- (void)virtualMachine:(MNDVirtualMachine *)vm
        didChangeState:(MNDVirtualMachineState)state
                 error:(nullable NSError *)error;
@end

/// Thread-safe: all Virtualization.framework calls are confined to a private queue.
NS_SWIFT_SENDABLE
@interface MNDVirtualMachine : NSObject

+ (BOOL)isSupported;
/// Host limits clamped to what Virtualization.framework accepts.
+ (NSUInteger)maximumCPUCount;
+ (uint64_t)maximumMemoryBytes;
/// Whether a disk can be attached to a running VM (macOS 15 and later).
+ (BOOL)canAttachDisksWhileRunning;

/// The complete virtual hardware for `config`. This is the only place
/// devices are added: anything not built here does not exist in the guest.
/// Creates the machine identifier and EFI variable store when missing.
+ (nullable VZVirtualMachineConfiguration *)virtualMachineConfigurationForConfig:(MNDVMConfig *)config
                                                                           error:(NSError **)error
    NS_SWIFT_NAME(virtualMachineConfiguration(for:));

- (nullable instancetype)initWithConfig:(MNDVMConfig *)config error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, weak, nullable) id<MNDVirtualMachineDelegate> delegate;
@property (atomic, readonly) MNDVirtualMachineState state;
/// Whether Virtualization would start this machine (not after an error).
@property (nonatomic, readonly) BOOL canStart;
@property (nonatomic, readonly) MNDVMConfig *config;
/// Virtualization's machine, for a view of its display (a
/// VZVirtualMachineViewAdaptor; everything else goes through this class).
@property (nonatomic, readonly) VZVirtualMachine *machine;

- (void)startWithCompletion:(void (^)(NSError *_Nullable error))completion;
/// ACPI power button; the guest shuts down cleanly.
- (void)requestStopWithCompletion:(void (^)(NSError *_Nullable error))completion;
/// Immediate power off.
- (void)forceStopWithCompletion:(void (^)(NSError *_Nullable error))completion;

/// Blocking check whether the guest accepts connections on a vsock port.
/// Must not be called on the main thread.
- (BOOL)probeVsockPort:(uint32_t)port timeout:(NSTimeInterval)timeout;

/// Blocking connect to a guest vsock port (host-initiated). Must not be
/// called on the main thread. Returns nil if the guest does not accept.
- (nullable MNDVsockChannel *)openVsockPort:(uint32_t)port timeout:(NSTimeInterval)timeout;

/// Replace the folders of the running VM's virtio-fs share. Fails when the
/// VM was started without runtime sharing.
- (void)setSharedDirectories:(NSArray<MNDSharedDirectory *> *)directories
                  completion:(void (^)(NSError *_Nullable error))completion;

/// Ask the guest (through the memory balloon) to use at most `bytes`;
/// clamped to the memory the VM booted with. Ignored while stopped.
- (void)setMemoryTargetBytes:(uint64_t)bytes NS_SWIFT_NAME(setMemoryTarget(bytes:));

/// A disk image as a USB disk of the running VM (one at a time), on the
/// controller usbDisks gave it; then taken away again.
- (void)attachDiskAtPath:(NSString *)path completion:(void (^)(NSError *_Nullable error))completion;
- (void)detachDiskWithCompletion:(void (^)(NSError *_Nullable error))completion;

/// Serve guest vsock `port` on a unix socket at `path` (0600).
- (BOOL)startBridgeAtPath:(NSString *)path port:(uint32_t)port error:(NSError **)error;
- (void)stopBridge;

/// A recovery boot's keyboard and pointer (Apple's private input API, the
/// one place Monad uses it): keys go down or up together, in order (Mac
/// virtual key codes); the pointer is at x, y (0…1 from the display's top
/// left) with `buttons` pressed (1: the primary one). NO with an error when
/// this macOS has no such API or the VM has no such device.
- (BOOL)pressKeys:(NSArray<NSNumber *> *)keyCodes down:(BOOL)down error:(NSError **)error
    NS_SWIFT_NAME(pressKeys(_:down:));
- (BOOL)pointAtX:(double)x y:(double)y buttons:(NSInteger)buttons error:(NSError **)error
    NS_SWIFT_NAME(point(x:y:buttons:));

@end

NS_ASSUME_NONNULL_END
