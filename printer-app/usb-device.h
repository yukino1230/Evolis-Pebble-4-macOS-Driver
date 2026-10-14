// Evolis のプリンタの USB デバイス(evolis-usb://)。usb-device.m
#ifndef EVOLIS_USB_DEVICE_H
#define EVOLIS_USB_DEVICE_H
#include <pappl/pappl.h>

#define EVOLIS_USB_URI   "evolis-usb://Evolis/Pebble%204"
#define EVOLIS_DEVICE_ID "MFG:Evolis;MDL:Pebble 4;CMD:EVOLIS;CLS:PRINTER;"

void evolis_usb_register(void);

#endif
