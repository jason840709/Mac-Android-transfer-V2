#ifndef LIBMTP_STUB_H
#define LIBMTP_STUB_H
#include <stdint.h>
#include <time.h>

typedef enum {
  LIBMTP_FILETYPE_FOLDER,
  LIBMTP_FILETYPE_UNKNOWN = 99
} LIBMTP_filetype_t;

typedef enum {
  LIBMTP_DEVICECAP_GetPartialObject,
  LIBMTP_DEVICECAP_SendPartialObject,
  LIBMTP_DEVICECAP_EditObjects,
  LIBMTP_DEVICECAP_MoveObject,
  LIBMTP_DEVICECAP_CopyObject
} LIBMTP_devicecap_t;

typedef enum {
  LIBMTP_PROPERTY_DateCreated = 0xDC08
} LIBMTP_property_t;

typedef enum {
  LIBMTP_ERROR_NONE,
  LIBMTP_ERROR_GENERAL,
  LIBMTP_ERROR_PTP_LAYER,
  LIBMTP_ERROR_USB_LAYER,
  LIBMTP_ERROR_MEMORY_ALLOCATION,
  LIBMTP_ERROR_NO_DEVICE_ATTACHED,
  LIBMTP_ERROR_STORAGE_FULL,
  LIBMTP_ERROR_CONNECTING,
  LIBMTP_ERROR_CANCELLED
} LIBMTP_error_number_t;

typedef struct LIBMTP_device_entry_struct {
  char *vendor;
  uint16_t vendor_id;
  char *product;
  uint16_t product_id;
  uint32_t device_flags;
} LIBMTP_device_entry_t;

typedef struct LIBMTP_raw_device_struct {
  LIBMTP_device_entry_t device_entry;
  uint32_t bus_location;
  uint8_t devnum;
} LIBMTP_raw_device_t;

typedef struct LIBMTP_error_struct {
  LIBMTP_error_number_t errornumber;
  char *error_text;
  struct LIBMTP_error_struct *next;
} LIBMTP_error_t;

typedef struct LIBMTP_file_struct {
  uint32_t item_id;
  uint32_t parent_id;
  uint32_t storage_id;
  char *filename;
  uint64_t filesize;
  time_t modificationdate;
  LIBMTP_filetype_t filetype;
  struct LIBMTP_file_struct *next;
} LIBMTP_file_t;

typedef struct LIBMTP_devicestorage_struct {
  uint32_t id;
  uint16_t StorageType;
  uint16_t FilesystemType;
  uint16_t AccessCapability;
  uint64_t MaxCapacity;
  uint64_t FreeSpaceInBytes;
  uint64_t FreeSpaceInObjects;
  char *StorageDescription;
  char *VolumeIdentifier;
  struct LIBMTP_devicestorage_struct *next;
  struct LIBMTP_devicestorage_struct *prev;
} LIBMTP_devicestorage_t;

typedef struct LIBMTP_mtpdevice_struct {
  uint8_t object_bitsize;
  void *params;
  void *usbinfo;
  LIBMTP_devicestorage_t *storage;
  LIBMTP_error_t *errorstack;
} LIBMTP_mtpdevice_t;

typedef int (*LIBMTP_progressfunc_t)(uint64_t, uint64_t, void const * const);

#define LIBMTP_STORAGE_SORTBY_NOTSORTED 0

void LIBMTP_Init(void);
LIBMTP_error_number_t LIBMTP_Detect_Raw_Devices(LIBMTP_raw_device_t **, int *);
LIBMTP_mtpdevice_t *LIBMTP_Open_Raw_Device_Uncached(LIBMTP_raw_device_t *);
void LIBMTP_Release_Device(LIBMTP_mtpdevice_t *);
int LIBMTP_Check_Capability(LIBMTP_mtpdevice_t *, LIBMTP_devicecap_t);
char *LIBMTP_Get_Manufacturername(LIBMTP_mtpdevice_t *);
char *LIBMTP_Get_Modelname(LIBMTP_mtpdevice_t *);
char *LIBMTP_Get_Serialnumber(LIBMTP_mtpdevice_t *);
char *LIBMTP_Get_Friendlyname(LIBMTP_mtpdevice_t *);
char *LIBMTP_Get_Deviceversion(LIBMTP_mtpdevice_t *);
void LIBMTP_FreeMemory(void *);
LIBMTP_error_t *LIBMTP_Get_Errorstack(LIBMTP_mtpdevice_t *);
void LIBMTP_Clear_Errorstack(LIBMTP_mtpdevice_t *);
int LIBMTP_Get_Storage(LIBMTP_mtpdevice_t *, int);
LIBMTP_file_t *LIBMTP_Get_Files_And_Folders(LIBMTP_mtpdevice_t *, uint32_t, uint32_t);
int LIBMTP_Is_Property_Supported(LIBMTP_mtpdevice_t *, LIBMTP_property_t, LIBMTP_filetype_t);
char *LIBMTP_Get_String_From_Object(LIBMTP_mtpdevice_t *, uint32_t, LIBMTP_property_t);
LIBMTP_file_t *LIBMTP_Get_Filemetadata(LIBMTP_mtpdevice_t *, uint32_t);
LIBMTP_file_t *LIBMTP_new_file_t(void);
void LIBMTP_destroy_file_t(LIBMTP_file_t *);
uint32_t LIBMTP_Create_Folder(LIBMTP_mtpdevice_t *, char *, uint32_t, uint32_t);
int LIBMTP_Set_Object_Filename(LIBMTP_mtpdevice_t *, uint32_t, char *);
int LIBMTP_Delete_Object(LIBMTP_mtpdevice_t *, uint32_t);
int LIBMTP_GetPartialObject(LIBMTP_mtpdevice_t *, uint32_t, uint64_t, uint32_t, unsigned char **, unsigned int *);
int LIBMTP_Get_File_To_File_Descriptor(LIBMTP_mtpdevice_t *, uint32_t, int, LIBMTP_progressfunc_t, void const * const);
int LIBMTP_Send_File_From_File_Descriptor(LIBMTP_mtpdevice_t *, int, LIBMTP_file_t *, LIBMTP_progressfunc_t, void const * const);

#endif
