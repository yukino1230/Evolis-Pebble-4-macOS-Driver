// Evolis のプリンタと USB でやり取りする「デバイス」を PAPPL に登録する(evolis-usb://)。
//
// PAPPL の USB は libusb を使うが、libusb は LGPL で静的に組み込みにくいので使わず、
// Evolis Utility(app/Sources/EvolisUSB.swift)と同じく macOS の IOUSBHost で直接読み書きする。
// プリンタのインターフェース(クラス 7)のバルク OUT に印刷データを書き、バルク IN から返事を読む。
#import <Foundation/Foundation.h>
#import <IOUSBHost/IOUSBHost.h>
#include "usb-device.h"

#define EVOLIS_VENDOR_ID 0x0F49

typedef struct {             // ARC の外で持つので void *(CFBridgingRetain / Release で管理する)
    void *interface, *out, *in;
} evolis_usb_t;
#define INTF(u) ((__bridge IOUSBHostInterface *)(u)->interface)
#define OUT(u)  ((__bridge IOUSBHostPipe *)(u)->out)
#define IN(u)   ((__bridge IOUSBHostPipe *)(u)->in)

// プリンタのインターフェースを探す。メーカー ID + クラスの検索条件は使えないので、全部見て選ぶ
static io_service_t find_interface(void) {
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &it) != KERN_SUCCESS)
        return IO_OBJECT_NULL;
    io_service_t s, found = IO_OBJECT_NULL;
    while (!found && (s = IOIteratorNext(it)) != IO_OBJECT_NULL) {
        NSNumber *vid = CFBridgingRelease(IORegistryEntryCreateCFProperty(s, CFSTR("idVendor"), kCFAllocatorDefault, 0));
        NSNumber *cls = CFBridgingRelease(IORegistryEntryCreateCFProperty(s, CFSTR("bInterfaceClass"), kCFAllocatorDefault, 0));
        if (vid.intValue == EVOLIS_VENDOR_ID && cls.intValue == 7) found = s;
        else IOObjectRelease(s);
    }
    IOObjectRelease(it);
    return found;
}

static bool usb_list(pappl_device_cb_t cb, void *data, pappl_deverror_cb_t err_cb, void *err_data) {
    (void)err_cb; (void)err_data;
    io_service_t s = find_interface();
    if (!s) return false;
    IOObjectRelease(s);
    return cb("Evolis Pebble 4 (USB)", EVOLIS_USB_URI, EVOLIS_DEVICE_ID, data);
}

static bool usb_open(pappl_device_t *device, const char *uri, const char *name) {
    (void)uri; (void)name;
    @autoreleasepool {
        // CUPS など、ほかがつかんでいる間は開けない。少し待ってやり直す
        for (int attempt = 0; attempt < 30; attempt++) {
            io_service_t s = find_interface();
            if (!s) { papplDeviceError(device, "Evolis printer not found on USB."); return false; }
            NSError *err = nil;
            IOUSBHostInterface *intf = [[IOUSBHostInterface alloc] initWithIOService:s options:IOUSBHostObjectInitOptionsNone
                                                                              queue:nil error:&err interestHandler:nil];
            IOObjectRelease(s);
            if (!intf) {
                if (err.code == kIOReturnExclusiveAccess) { sleep(2); continue; }
                papplDeviceError(device, "Unable to open the Evolis printer: %s", err.localizedDescription.UTF8String);
                return false;
            }
            // バルクの OUT / IN のエンドポイントを探す
            const IOUSBConfigurationDescriptor *config = intf.configurationDescriptor;
            const IOUSBInterfaceDescriptor *idesc = intf.interfaceDescriptor;
            const IOUSBEndpointDescriptor *ep = IOUSBGetNextEndpointDescriptor(config, idesc, NULL);
            uint8_t out_addr = 0, in_addr = 0;
            while (ep) {
                if ((ep->bmAttributes & 0x03) == 0x02) {
                    if (ep->bEndpointAddress & 0x80) in_addr = ep->bEndpointAddress;
                    else out_addr = ep->bEndpointAddress;
                }
                ep = IOUSBGetNextEndpointDescriptor(config, idesc, (const IOUSBDescriptorHeader *)ep);
            }
            IOUSBHostPipe *out = out_addr ? [intf copyPipeWithAddress:out_addr error:&err] : nil;
            IOUSBHostPipe *in = in_addr ? [intf copyPipeWithAddress:in_addr error:&err] : nil;
            if (!out || !in) {
                [intf destroy];
                papplDeviceError(device, "The Evolis printer has no bulk endpoints.");
                return false;
            }
            evolis_usb_t *u = calloc(1, sizeof *u);
            u->interface = (void *)CFBridgingRetain(intf);
            u->out = (void *)CFBridgingRetain(out);
            u->in = (void *)CFBridgingRetain(in);
            papplDeviceSetData(device, u);
            return true;
        }
        papplDeviceError(device, "The Evolis printer is busy (used by another program).");
        return false;
    }
}

static void usb_close(pappl_device_t *device) {
    evolis_usb_t *u = papplDeviceGetData(device);
    if (!u) return;
    @autoreleasepool {
        [INTF(u) destroy];
        CFBridgingRelease(u->out);
        CFBridgingRelease(u->in);
        CFBridgingRelease(u->interface);
    }
    free(u);
    papplDeviceSetData(device, NULL);
}

static ssize_t usb_write(pappl_device_t *device, const void *buffer, size_t bytes) {
    evolis_usb_t *u = papplDeviceGetData(device);
    size_t done = 0;
    @autoreleasepool {
        while (done < bytes) {
            size_t n = bytes - done < 65536 ? bytes - done : 65536;
            NSMutableData *chunk = [NSMutableData dataWithBytes:(const char *)buffer + done length:n];
            NSUInteger sent = 0;
            NSError *err = nil;
            // 本体が前のカードを刷っている間は受け取りが止まるので、待ち時間を長めにする
            if (![OUT(u) sendIORequestWithData:chunk bytesTransferred:&sent completionTimeout:120 error:&err] || !sent) {
                papplDeviceError(device, "Unable to write to the Evolis printer: %s", err.localizedDescription.UTF8String);
                return -1;
            }
            done += sent;
        }
    }
    return (ssize_t)done;
}

static ssize_t usb_read(pappl_device_t *device, void *buffer, size_t bytes) {
    evolis_usb_t *u = papplDeviceGetData(device);
    @autoreleasepool {
        NSMutableData *data = [NSMutableData dataWithLength:bytes];
        NSUInteger got = 0;
        NSError *err = nil;
        if (![IN(u) sendIORequestWithData:data bytesTransferred:&got completionTimeout:2 error:&err])
            return err.code == kIOReturnTimeout ? 0 : -1;
        memcpy(buffer, data.bytes, got);
        return (ssize_t)got;
    }
}

static pappl_preason_t usb_status(pappl_device_t *device) {
    (void)device;
    return PAPPL_PREASON_NONE;
}

static char *usb_id(pappl_device_t *device, char *buffer, size_t bufsize) {
    (void)device;
    strlcpy(buffer, EVOLIS_DEVICE_ID, bufsize);
    return buffer;
}

void evolis_usb_register(void) {
    papplDeviceAddScheme("evolis-usb", PAPPL_DEVTYPE_CUSTOM_LOCAL, usb_list, usb_open, usb_close,
                         usb_read, usb_write, usb_status, usb_id);
}
