//
//  MNDVirtualMachine.m
//

#import "MNDVirtualMachine.h"

#import <Virtualization/Virtualization.h>
#import <os/log.h>

#include "mnd_bridge.h"
#include "mnd_rotlog.h"

/* Guest console output kept on disk per VM (twice this at most, with the
 * rotated file): a guest can print without end. */
static const size_t kConsoleLogCap = 8u << 20;

NSErrorDomain const MNDVirtualMachineErrorDomain = @"dev.monad.vm";

static os_log_t MNDLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("dev.monad", "vm"); });
    return log;
}

static NSError *MNDError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:MNDVirtualMachineErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

@implementation MNDSharedDirectory
- (instancetype)initWithName:(NSString *)name path:(NSString *)path readOnly:(BOOL)readOnly {
    if ((self = [super init])) {
        _name = [name copy];
        _path = [path copy];
        _readOnly = readOnly;
    }
    return self;
}
@end

@implementation MNDVMConfig
- (instancetype)init {
    if ((self = [super init])) {
        _cpuCount = 2;
        _memoryBytes = 4ull << 30;
        _networkEnabled = YES;
        _sharingTag = @"monad";
        _sharedDirectories = @[];
    }
    return self;
}
@end

@implementation MNDVsockChannel {
    VZVirtioSocketConnection *_connection;
}

- (instancetype)initWithConnection:(VZVirtioSocketConnection *)connection {
    if ((self = [super init])) _connection = connection;
    return self;
}

- (int)fileDescriptor {
    @synchronized(self) {
        return _connection ? _connection.fileDescriptor : -1;
    }
}

- (void)close {
    @synchronized(self) {
        [_connection close];
        _connection = nil;
    }
}

- (void)dealloc {
    [_connection close];
}
@end

@interface MNDVirtualMachine () <VZVirtualMachineDelegate>
@end

#pragma mark - Apple's private input API

// Apple's private input API in Virtualization (found on macOS 27, see
// docs/MACOS.md): -[VZVirtualMachine _keyboards] gives _VZKeyboard objects
// taking _VZKeyEvent (type 0 down, 1 up; Mac key codes), and
// -_pointingDevices gives a _VZScreenCoordinatePointingDevice taking
// _VZScreenCoordinatePointerEvent (a point from 0 to 1, the buttons held).
// Every selector is checked before use. Never call -[VZGraphicsDisplay
// _takeScreenshotWithCompletionHandler:]: the VM service only allows it
// with Apple's own entitlement and kills the VM otherwise.
@protocol MNDPrivateKeyEvent <NSObject>
- (instancetype)initWithType:(NSInteger)type keyCode:(uint16_t)keyCode;
@end
@protocol MNDPrivateKeyboard <NSObject>
- (void)sendKeyEvents:(NSArray *)events;
@end
@protocol MNDPrivatePointerEvent <NSObject>
- (instancetype)initWithLocation:(CGPoint)location pressedButtons:(NSInteger)buttons;
@end
@protocol MNDPrivatePointer <NSObject>
- (void)sendPointerEvents:(NSArray *)events;
@end

static NSError *MNDNoInput(NSString *what) {
    return MNDError(7, [NSString stringWithFormat:@"This macOS gives Monad no way to use the VM's %@.", what]);
}

@implementation MNDVirtualMachine {
    dispatch_queue_t _queue;
    VZVirtualMachine *_vm;
    mnd_bridge *_bridge;
    uint32_t _bridgePort;
    // Live vsock connections handed to the bridge, keyed by file descriptor.
    NSMutableDictionary<NSNumber *, VZVirtioSocketConnection *> *_connections;
    NSLock *_connectionsLock;
    MNDVirtualMachineState _state;
    uint64_t _memorySize;
    // Guest console: a pipe read here and written to a size-capped log.
    dispatch_queue_t _consoleQueue;
    dispatch_source_t _console;
    mnd_rotlog *_consoleLog;
    // The disk attached while running (Repair Disk); used on _queue only.
    id _usbDisk;
}

+ (BOOL)isSupported {
    return VZVirtualMachine.isSupported;
}

+ (NSUInteger)maximumCPUCount {
    return MIN(VZVirtualMachineConfiguration.maximumAllowedCPUCount, NSProcessInfo.processInfo.processorCount);
}

+ (uint64_t)maximumMemoryBytes {
    return MIN(VZVirtualMachineConfiguration.maximumAllowedMemorySize, NSProcessInfo.processInfo.physicalMemory);
}

+ (BOOL)canAttachDisksWhileRunning {
    if (@available(macOS 15, *)) return YES;
    return NO;
}

- (instancetype)initWithConfig:(MNDVMConfig *)config error:(NSError **)error {
    if (!(self = [super init])) return nil;
    _config = config;
    _queue = dispatch_queue_create("dev.monad.vm", DISPATCH_QUEUE_SERIAL);
    _connections = [NSMutableDictionary dictionary];
    _connectionsLock = [NSLock new];

    NSFileHandle *consoleOut = nil;
    if (config.serialLogPath && !(consoleOut = [self openConsoleLog:config.serialLogPath error:error])) return nil;
    VZVirtualMachineConfiguration *vzc = [MNDVirtualMachine configurationForConfig:config
                                                                     consoleOutput:consoleOut
                                                                             error:error];
    if (!vzc) return nil;
    NSError *validation = nil;
    if (![vzc validateWithError:&validation]) {
        if (error) *error = validation;
        return nil;
    }
    _memorySize = vzc.memorySize;
    __block VZVirtualMachine *vm = nil;
    dispatch_sync(_queue, ^{
        vm = [[VZVirtualMachine alloc] initWithConfiguration:vzc queue:self->_queue];
        vm.delegate = self;
    });
    _vm = vm;
    return self;
}

- (void)dealloc {
    [self stopBridge];
    if (_console) dispatch_source_cancel(_console); /* closes the pipe and the log */
}

#pragma mark - Console log

/* Returns the write end for the guest's console; the read end is drained on
 * a private queue into a log that rotates at kConsoleLogCap. */
- (nullable NSFileHandle *)openConsoleLog:(NSString *)path error:(NSError **)error {
    int e = 0;
    mnd_rotlog *log = mnd_rotlog_open(path.fileSystemRepresentation, kConsoleLogCap, &e);
    if (!log) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:e userInfo:nil];
        return nil;
    }
    int fds[2];
    if (pipe(fds) != 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        mnd_rotlog_close(log);
        return nil;
    }
    fcntl(fds[0], F_SETFD, FD_CLOEXEC);
    fcntl(fds[1], F_SETFD, FD_CLOEXEC);
    fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL) | O_NONBLOCK);
    int rfd = fds[0];
    _consoleLog = log;
    _consoleQueue = dispatch_queue_create("dev.monad.vm.console", DISPATCH_QUEUE_SERIAL);
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)rfd, 0, _consoleQueue);
    char *buf = malloc(64 * 1024);
    dispatch_source_set_event_handler(src, ^{
        for (int i = 0; i < 16; i++) { /* bounded work per event */
            ssize_t n = read(rfd, buf, 64 * 1024);
            if (n > 0) {
                mnd_rotlog_write(log, buf, (size_t)n);
                continue;
            }
            if (n < 0 && (errno == EAGAIN || errno == EINTR)) return;
            dispatch_source_cancel(src); /* EOF: never spin on it */
            return;
        }
    });
    dispatch_source_set_cancel_handler(src, ^{
        close(rfd);
        free(buf);
        mnd_rotlog_close(log);
    });
    _console = src;
    dispatch_resume(src);
    return [[NSFileHandle alloc] initWithFileDescriptor:fds[1] closeOnDealloc:YES];
}

#pragma mark - Shares

- (void)setSharedDirectories:(NSArray<MNDSharedDirectory *> *)directories
                  completion:(void (^)(NSError *_Nullable))completion {
    NSError *error = nil;
    VZMultipleDirectoryShare *share = [MNDVirtualMachine shareWithDirectories:directories error:&error];
    if (!share) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
        return;
    }
    dispatch_async(_queue, ^{
        VZVirtioFileSystemDevice *fs = nil;
        for (VZDirectorySharingDevice *device in self->_vm.directorySharingDevices) {
            if ([device isKindOfClass:VZVirtioFileSystemDevice.class]) fs = (VZVirtioFileSystemDevice *)device;
        }
        NSError *e = nil;
        if (!fs) {
            e = MNDError(4, @"This VM was started without folder sharing; restart it to share folders.");
        } else {
            fs.share = share;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(e); });
    });
}

#pragma mark - Memory

- (void)setMemoryTargetBytes:(uint64_t)bytes {
    uint64_t target = MAX(VZVirtualMachineConfiguration.minimumAllowedMemorySize, MIN(bytes, _memorySize));
    target -= target % (1ull << 20); // whole MiB, like the boot size
    dispatch_async(_queue, ^{
        if (self->_vm.state != VZVirtualMachineStateRunning) return;
        for (VZMemoryBalloonDevice *device in self->_vm.memoryBalloonDevices) {
            if ([device isKindOfClass:VZVirtioTraditionalMemoryBalloonDevice.class]) {
                ((VZVirtioTraditionalMemoryBalloonDevice *)device).targetVirtualMachineMemorySize = target;
            }
        }
    });
}

#pragma mark - Configuration

+ (nullable VZGenericMachineIdentifier *)machineIdentifierAtPath:(NSString *)path error:(NSError **)error {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data) {
        VZGenericMachineIdentifier *mid = [[VZGenericMachineIdentifier alloc] initWithDataRepresentation:data];
        if (mid) return mid;
        os_log_error(MNDLog(), "invalid machine identifier at %{public}@, regenerating", path);
    }
    VZGenericMachineIdentifier *mid = [[VZGenericMachineIdentifier alloc] init];
    if (![mid.dataRepresentation writeToFile:path options:NSDataWritingAtomic error:error]) return nil;
    return mid;
}

/// A macOS guest's platform: its hardware model and auxiliary storage as its
/// install left them, its machine identifier (made once), Apple's boot loader.
+ (BOOL)configureMacPlatform:(VZVirtualMachineConfiguration *)vzc config:(MNDVMConfig *)c error:(NSError **)error {
    NSString *missing = @"This macOS VM's install is incomplete (its platform files are missing). Delete it and make it again.";
    NSData *hw = c.hardwareModelPath ? [NSData dataWithContentsOfFile:c.hardwareModelPath] : nil;
    VZMacHardwareModel *model = hw ? [[VZMacHardwareModel alloc] initWithDataRepresentation:hw] : nil;
    if (!model || !c.auxiliaryStoragePath || ![NSFileManager.defaultManager fileExistsAtPath:c.auxiliaryStoragePath]) {
        if (error) *error = MNDError(6, missing);
        return NO;
    }
    if (!model.supported) {
        if (error) *error = MNDError(6, @"This Mac cannot run this macOS VM (its hardware model is not supported here).");
        return NO;
    }
    NSData *midData = [NSData dataWithContentsOfFile:c.machineIdentifierPath];
    VZMacMachineIdentifier *mid = midData ? [[VZMacMachineIdentifier alloc] initWithDataRepresentation:midData] : nil;
    if (!mid) {
        mid = [[VZMacMachineIdentifier alloc] init];
        if (![mid.dataRepresentation writeToFile:c.machineIdentifierPath options:NSDataWritingAtomic error:error]) return NO;
    }
    VZMacPlatformConfiguration *platform = [[VZMacPlatformConfiguration alloc] init];
    platform.hardwareModel = model;
    platform.machineIdentifier = mid;
    platform.auxiliaryStorage = [[VZMacAuxiliaryStorage alloc] initWithURL:[NSURL fileURLWithPath:c.auxiliaryStoragePath]];
    vzc.platform = platform;
    vzc.bootLoader = [[VZMacOSBootLoader alloc] init];
    return YES;
}

+ (nullable VZEFIVariableStore *)variableStoreAtPath:(NSString *)path error:(NSError **)error {
    NSURL *url = [NSURL fileURLWithPath:path];
    if ([NSFileManager.defaultManager fileExistsAtPath:url.path]) {
        return [[VZEFIVariableStore alloc] initWithURL:url];
    }
    return [[VZEFIVariableStore alloc] initCreatingVariableStoreAtURL:url options:0 error:error];
}

+ (nullable VZMultipleDirectoryShare *)shareWithDirectories:(NSArray<MNDSharedDirectory *> *)directories
                                                      error:(NSError **)error {
    NSMutableDictionary<NSString *, VZSharedDirectory *> *dirs = [NSMutableDictionary dictionary];
    for (MNDSharedDirectory *d in directories) {
        if (![VZMultipleDirectoryShare validateName:d.name error:error]) return nil;
        if (dirs[d.name]) {
            if (error) *error = MNDError(3, [NSString stringWithFormat:@"Duplicate shared folder name \u201c%@\u201d.", d.name]);
            return nil;
        }
        dirs[d.name] = [[VZSharedDirectory alloc] initWithURL:[NSURL fileURLWithPath:d.path isDirectory:YES]
                                                     readOnly:d.readOnly];
    }
    return [[VZMultipleDirectoryShare alloc] initWithDirectories:dirs];
}

+ (nullable VZVirtualMachineConfiguration *)virtualMachineConfigurationForConfig:(MNDVMConfig *)c
                                                                           error:(NSError **)error {
    NSFileHandle *sink = c.serialLogPath ? [NSFileHandle fileHandleForWritingAtPath:@"/dev/null"] : nil;
    return [self configurationForConfig:c consoleOutput:sink error:error];
}

+ (nullable VZVirtualMachineConfiguration *)configurationForConfig:(MNDVMConfig *)c
                                                     consoleOutput:(nullable NSFileHandle *)consoleOut
                                                             error:(NSError **)error {
    VZVirtualMachineConfiguration *vzc = [[VZVirtualMachineConfiguration alloc] init];

    NSUInteger cpus = MAX(VZVirtualMachineConfiguration.minimumAllowedCPUCount,
                          MIN(c.cpuCount, [MNDVirtualMachine maximumCPUCount]));
    uint64_t mem = MAX(VZVirtualMachineConfiguration.minimumAllowedMemorySize,
                       MIN(c.memoryBytes, [MNDVirtualMachine maximumMemoryBytes]));
    mem -= mem % (1ull << 20); // must be a multiple of 1 MiB
    vzc.CPUCount = cpus;
    vzc.memorySize = mem;

    if (c.macOS) {
        // Apple's platform, from what the install wrote.
        if (![self configureMacPlatform:vzc config:c error:error]) return nil;
    } else {
        // Platform + UEFI boot.
        VZGenericMachineIdentifier *mid = [self machineIdentifierAtPath:c.machineIdentifierPath error:error];
        if (!mid) return nil;
        VZGenericPlatformConfiguration *platform = [[VZGenericPlatformConfiguration alloc] init];
        platform.machineIdentifier = mid;
        vzc.platform = platform;

        VZEFIVariableStore *store = [self variableStoreAtPath:c.efiVariableStorePath error:error];
        if (!store) return nil;
        VZEFIBootLoader *boot = [[VZEFIBootLoader alloc] init];
        boot.variableStore = store;
        vzc.bootLoader = boot;
    }

    // Storage: root disk, then the read-only cloud-init seed.
    NSMutableArray<VZStorageDeviceConfiguration *> *storage = [NSMutableArray array];
    VZDiskImageStorageDeviceAttachment *root =
        [[VZDiskImageStorageDeviceAttachment alloc] initWithURL:[NSURL fileURLWithPath:c.diskPath]
                                                       readOnly:NO
                                                    cachingMode:VZDiskImageCachingModeAutomatic
                                            synchronizationMode:VZDiskImageSynchronizationModeFull
                                                          error:error];
    if (!root) return nil;
    [storage addObject:[[VZVirtioBlockDeviceConfiguration alloc] initWithAttachment:root]];
    if (c.seedISOPath) {
        VZDiskImageStorageDeviceAttachment *seed =
            [[VZDiskImageStorageDeviceAttachment alloc] initWithURL:[NSURL fileURLWithPath:c.seedISOPath]
                                                           readOnly:YES
                                                              error:error];
        if (!seed) return nil;
        [storage addObject:[[VZVirtioBlockDeviceConfiguration alloc] initWithAttachment:seed]];
    }
    vzc.storageDevices = storage;

    // Network: a Monad network (a socket to monad-netd) or Apple's NAT. With
    // networking disabled the guest has no NIC at all.
    if (c.networkEnabled) {
        VZVirtioNetworkDeviceConfiguration *net = [[VZVirtioNetworkDeviceConfiguration alloc] init];
        if (c.networkThroughSocket) {
            if (!c.networkFileHandle) {
                if (error) *error = MNDError(5, @"The VM's network is not connected (monad-netd gave no socket).");
                return nil;
            }
            net.attachment = [[VZFileHandleNetworkDeviceAttachment alloc] initWithFileHandle:c.networkFileHandle];
        } else {
            net.attachment = [[VZNATNetworkDeviceAttachment alloc] init];
        }
        VZMACAddress *mac = c.macAddress ? [[VZMACAddress alloc] initWithString:c.macAddress] : nil;
        if (!mac) {
            mac = [VZMACAddress randomLocallyAdministeredAddress];
            c.macAddress = mac.string;
        }
        net.MACAddress = mac;
        vzc.networkDevices = @[ net ];
    }

    vzc.entropyDevices = @[ [[VZVirtioEntropyDeviceConfiguration alloc] init] ];
    if (!c.macOS) vzc.memoryBalloonDevices = @[ [[VZVirtioTraditionalMemoryBalloonDeviceConfiguration alloc] init] ];
    vzc.socketDevices = @[ [[VZVirtioSocketDeviceConfiguration alloc] init] ];

    // Serial console (hvc0) to a log file for boot diagnostics.
    if (consoleOut) {
        VZFileHandleSerialPortAttachment *att =
            [[VZFileHandleSerialPortAttachment alloc] initWithFileHandleForReading:nil fileHandleForWriting:consoleOut];
        VZVirtioConsoleDeviceSerialPortConfiguration *serial = [[VZVirtioConsoleDeviceSerialPortConfiguration alloc] init];
        serial.attachment = att;
        vzc.serialPorts = @[ serial ];
    }

    // A macOS guest's display, keyboard and pointer: its desktop, and
    // recovery driven by Monad. A Linux guest has none.
    if (c.displayWidth > 0) {
        VZMacGraphicsDeviceConfiguration *gfx = [[VZMacGraphicsDeviceConfiguration alloc] init];
        gfx.displays = @[ [[VZMacGraphicsDisplayConfiguration alloc] initWithWidthInPixels:(NSInteger)c.displayWidth
                                                                             heightInPixels:(NSInteger)c.displayHeight
                                                                              pixelsPerInch:(NSInteger)c.displayPixelsPerInch] ];
        vzc.graphicsDevices = @[ gfx ];
        vzc.keyboards = @[ [[VZUSBKeyboardConfiguration alloc] init] ];
        vzc.pointingDevices = @[ [[VZUSBScreenCoordinatePointingDeviceConfiguration alloc] init] ];
    }

    // Host folders: one virtio-fs device, only on VMs that opted in. It is
    // present even with no folders so shares can be added while running.
    if (c.runtimeSharingEnabled) {
        NSError *tagErr = nil;
        if (![VZVirtioFileSystemDeviceConfiguration validateTag:c.sharingTag error:&tagErr]) {
            if (error) *error = tagErr;
            return nil;
        }
        VZMultipleDirectoryShare *share = [MNDVirtualMachine shareWithDirectories:c.sharedDirectories error:error];
        if (!share) return nil;
        VZVirtioFileSystemDeviceConfiguration *fs =
            [[VZVirtioFileSystemDeviceConfiguration alloc] initWithTag:c.sharingTag];
        fs.share = share;
        vzc.directorySharingDevices = @[ fs ];
    }

    // Repair Disk's temporary VM only: a disk comes once it runs.
    if (c.usbDisks) {
        if (@available(macOS 15, *)) vzc.usbControllers = @[ [[VZXHCIControllerConfiguration alloc] init] ];
    }
    return vzc;
}

#pragma mark - State

- (VZVirtualMachine *)machine {
    return _vm;
}

- (BOOL)canStart {
    __block BOOL can = NO;
    dispatch_sync(_queue, ^{ can = self->_vm.canStart; });
    return can;
}

- (MNDVirtualMachineState)state {
    @synchronized(self) {
        return _state;
    }
}

- (void)setState:(MNDVirtualMachineState)state error:(nullable NSError *)error {
    @synchronized(self) {
        _state = state;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate virtualMachine:self didChangeState:state error:error];
    });
}

#pragma mark - Lifecycle

- (void)startWithCompletion:(void (^)(NSError *_Nullable))completion {
    dispatch_async(_queue, ^{
        if (!self->_vm.canStart) {
            NSError *e = MNDError(1, @"The virtual machine cannot be started in its current state.");
            dispatch_async(dispatch_get_main_queue(), ^{ completion(e); });
            return;
        }
        [self setState:MNDVirtualMachineStateStarting error:nil];
        if (self->_consoleLog) {
            mnd_rotlog *log = self->_consoleLog;
            dispatch_sync(self->_consoleQueue, ^{ mnd_rotlog_reset(log); }); /* each boot starts a fresh log */
        }
        void (^started)(NSError *_Nullable) = ^(NSError *_Nullable err) {
            if (err) os_log_error(MNDLog(), "start failed: %{public}@", err);
            [self setState:err ? MNDVirtualMachineStateError : MNDVirtualMachineStateRunning error:err];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(err); });
        };
        if (self.config.recovery) {
            VZMacOSVirtualMachineStartOptions *options = [[VZMacOSVirtualMachineStartOptions alloc] init];
            options.startUpFromMacOSRecovery = YES;
            [self->_vm startWithOptions:options completionHandler:started];
        } else {
            [self->_vm startWithCompletionHandler:started];
        }
    });
}

- (void)requestStopWithCompletion:(void (^)(NSError *_Nullable))completion {
    dispatch_async(_queue, ^{
        NSError *err = nil;
        if (!self->_vm.canRequestStop) {
            err = MNDError(2, @"The guest cannot be asked to stop right now.");
        } else if ([self->_vm requestStopWithError:&err]) {
            [self setState:MNDVirtualMachineStateStopping error:nil];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(err); });
    });
}

- (void)forceStopWithCompletion:(void (^)(NSError *_Nullable))completion {
    dispatch_async(_queue, ^{
        if (!self->_vm.canStop) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
            return;
        }
        [self->_vm stopWithCompletionHandler:^(NSError *_Nullable err) {
            if (!err) [self setState:MNDVirtualMachineStateStopped error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(err); });
        }];
    });
}

- (void)guestDidStopVirtualMachine:(VZVirtualMachine *)virtualMachine {
    os_log_info(MNDLog(), "guest stopped");
    [self setState:MNDVirtualMachineStateStopped error:nil];
}

- (void)virtualMachine:(VZVirtualMachine *)virtualMachine didStopWithError:(NSError *)error {
    os_log_error(MNDLog(), "virtual machine stopped with error: %{public}@", error);
    [self setState:MNDVirtualMachineStateError error:error];
}

#pragma mark - A disk while running (Repair Disk)

- (void)attachDiskAtPath:(NSString *)path completion:(void (^)(NSError *_Nullable))completion {
    if (@available(macOS 15, *)) {
        dispatch_async(_queue, ^{
            VZUSBController *usb = self->_vm.usbControllers.firstObject;
            NSError *err = nil;
            VZDiskImageStorageDeviceAttachment *disk =
                usb && !self->_usbDisk
                    ? [[VZDiskImageStorageDeviceAttachment alloc] initWithURL:[NSURL fileURLWithPath:path]
                                                                     readOnly:NO
                                                                  cachingMode:VZDiskImageCachingModeAutomatic
                                                          synchronizationMode:VZDiskImageSynchronizationModeFull
                                                                        error:&err]
                    : nil;
            if (!disk) {
                if (!err) err = MNDError(7, usb ? @"A disk is attached already." : @"This VM was started without a USB controller.");
                dispatch_async(dispatch_get_main_queue(), ^{ completion(err); });
                return;
            }
            VZUSBMassStorageDevice *device =
                [[VZUSBMassStorageDevice alloc] initWithConfiguration:[[VZUSBMassStorageDeviceConfiguration alloc] initWithAttachment:disk]];
            [usb attachDevice:device completionHandler:^(NSError *_Nullable attachErr) {
                if (!attachErr) self->_usbDisk = device;
                dispatch_async(dispatch_get_main_queue(), ^{ completion(attachErr); });
            }];
        });
    } else {
        completion(MNDError(7, @"Attaching a disk to a running VM needs macOS 15 or later."));
    }
}

- (void)detachDiskWithCompletion:(void (^)(NSError *_Nullable))completion {
    if (@available(macOS 15, *)) {
        dispatch_async(_queue, ^{
            VZUSBController *usb = self->_vm.usbControllers.firstObject;
            id<VZUSBDevice> device = self->_usbDisk;
            if (!usb || !device) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
                return;
            }
            [usb detachDevice:device completionHandler:^(NSError *_Nullable err) {
                if (!err) self->_usbDisk = nil;
                dispatch_async(dispatch_get_main_queue(), ^{ completion(err); });
            }];
        });
    } else {
        completion(nil);
    }
}

#pragma mark - vsock

/// Connect on the VM queue; blocks the calling (non-VM, non-main) thread.
- (nullable VZVirtioSocketConnection *)connectPort:(uint32_t)port timeout:(NSTimeInterval)timeout {
    NSAssert(!NSThread.isMainThread, @"vsock connect must not block the main thread");
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block VZVirtioSocketConnection *result = nil;
    __block BOOL abandoned = NO;
    NSObject *lock = [NSObject new];
    dispatch_async(_queue, ^{
        VZVirtioSocketDevice *dev = (VZVirtioSocketDevice *)self->_vm.socketDevices.firstObject;
        if (!dev || self->_vm.state != VZVirtualMachineStateRunning) {
            dispatch_semaphore_signal(sem);
            return;
        }
        [dev connectToPort:port
            completionHandler:^(VZVirtioSocketConnection *_Nullable conn, NSError *_Nullable err) {
                @synchronized(lock) {
                    if (abandoned) {
                        [conn close];
                    } else {
                        result = conn;
                    }
                }
                dispatch_semaphore_signal(sem);
            }];
    });
    long timedOut = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
    @synchronized(lock) {
        if (timedOut) {
            abandoned = YES;
            [result close];
            return nil;
        }
        return result;
    }
}

- (BOOL)probeVsockPort:(uint32_t)port timeout:(NSTimeInterval)timeout {
    VZVirtioSocketConnection *conn = [self connectPort:port timeout:timeout];
    [conn close];
    return conn != nil;
}

- (nullable MNDVsockChannel *)openVsockPort:(uint32_t)port timeout:(NSTimeInterval)timeout {
    VZVirtioSocketConnection *conn = [self connectPort:port timeout:timeout];
    return conn ? [[MNDVsockChannel alloc] initWithConnection:conn] : nil;
}

static int bridge_connect(void *ctx) {
    MNDVirtualMachine *self = (__bridge MNDVirtualMachine *)ctx;
    VZVirtioSocketConnection *conn = [self connectPort:self->_bridgePort timeout:10];
    if (!conn) return -1;
    int fd = conn.fileDescriptor;
    [self->_connectionsLock lock];
    self->_connections[@(fd)] = conn;
    [self->_connectionsLock unlock];
    return fd;
}

static void bridge_release(void *ctx, int fd) {
    MNDVirtualMachine *self = (__bridge MNDVirtualMachine *)ctx;
    [self->_connectionsLock lock];
    VZVirtioSocketConnection *conn = self->_connections[@(fd)];
    [self->_connections removeObjectForKey:@(fd)];
    [self->_connectionsLock unlock];
    [conn close]; // closes fd
}

- (BOOL)startBridgeAtPath:(NSString *)path port:(uint32_t)port error:(NSError **)error {
    [self stopBridge];
    _bridgePort = port;
    int err = 0;
    mnd_bridge_upstream up = {(__bridge void *)self, bridge_connect, bridge_release};
    _bridge = mnd_bridge_start(path.fileSystemRepresentation, up, &err);
    if (!_bridge) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:err userInfo:nil];
        return NO;
    }
    return YES;
}

- (void)stopBridge {
    if (_bridge) {
        mnd_bridge_stop(_bridge);
        _bridge = NULL;
    }
}

#pragma mark - Recovery input

- (BOOL)pressKeys:(NSArray<NSNumber *> *)keyCodes down:(BOOL)down error:(NSError **)error {
    __block NSError *problem = nil;
    dispatch_sync(_queue, ^{
        Class eventClass = NSClassFromString(@"_VZKeyEvent");
        SEL keyboardsSel = NSSelectorFromString(@"_keyboards");
        if (!eventClass || ![eventClass instancesRespondToSelector:@selector(initWithType:keyCode:)]
            || ![self->_vm respondsToSelector:keyboardsSel]) {
            problem = MNDNoInput(@"keyboard");
            return;
        }
        NSArray *keyboards = [self->_vm valueForKey:@"_keyboards"];
        id<MNDPrivateKeyboard> keyboard = keyboards.firstObject;
        if (![keyboard respondsToSelector:@selector(sendKeyEvents:)]) {
            problem = MNDNoInput(@"keyboard");
            return;
        }
        NSMutableArray *events = [NSMutableArray arrayWithCapacity:keyCodes.count];
        for (NSNumber *code in keyCodes) {
            id<MNDPrivateKeyEvent> e = [eventClass alloc];
            [events addObject:[e initWithType:down ? 0 : 1 keyCode:code.unsignedShortValue]];
        }
        [keyboard sendKeyEvents:events];
    });
    if (problem && error) *error = problem;
    return problem == nil;
}

- (BOOL)pointAtX:(double)x y:(double)y buttons:(NSInteger)buttons error:(NSError **)error {
    __block NSError *problem = nil;
    dispatch_sync(_queue, ^{
        Class eventClass = NSClassFromString(@"_VZScreenCoordinatePointerEvent");
        SEL pointersSel = NSSelectorFromString(@"_pointingDevices");
        if (!eventClass || ![eventClass instancesRespondToSelector:@selector(initWithLocation:pressedButtons:)]
            || ![self->_vm respondsToSelector:pointersSel]) {
            problem = MNDNoInput(@"pointer");
            return;
        }
        NSArray *pointers = [self->_vm valueForKey:@"_pointingDevices"];
        id<MNDPrivatePointer> pointer = pointers.firstObject;
        if (![pointer respondsToSelector:@selector(sendPointerEvents:)]) {
            problem = MNDNoInput(@"pointer");
            return;
        }
        id<MNDPrivatePointerEvent> e = [eventClass alloc];
        [pointer sendPointerEvents:@[ [e initWithLocation:CGPointMake(x, y) pressedButtons:buttons] ]];
    });
    if (problem && error) *error = problem;
    return problem == nil;
}

@end
