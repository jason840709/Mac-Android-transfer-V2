#ifndef LIBUSB_STUB_H
#define LIBUSB_STUB_H

#include <stdint.h>
#include <sys/types.h>

typedef struct libusb_context libusb_context;
typedef struct libusb_device libusb_device;

struct libusb_device_descriptor {
    uint8_t bLength;
    uint8_t bDescriptorType;
    uint16_t bcdUSB;
    uint8_t bDeviceClass;
    uint8_t bDeviceSubClass;
    uint8_t bDeviceProtocol;
    uint8_t bMaxPacketSize0;
    uint16_t idVendor;
    uint16_t idProduct;
    uint16_t bcdDevice;
    uint8_t iManufacturer;
    uint8_t iProduct;
    uint8_t iSerialNumber;
    uint8_t bNumConfigurations;
};

#define LIBUSB_SUCCESS 0

int libusb_init(libusb_context **context);
void libusb_exit(libusb_context *context);
ssize_t libusb_get_device_list(libusb_context *context, libusb_device ***list);
void libusb_free_device_list(libusb_device **list, int unref_devices);
uint8_t libusb_get_bus_number(libusb_device *device);
uint8_t libusb_get_device_address(libusb_device *device);
int libusb_get_device_descriptor(libusb_device *device, struct libusb_device_descriptor *descriptor);

#endif
