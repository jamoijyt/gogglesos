/* GogglesXR overlay extension for Godot 4.4+.
 *
 * Godot has no built-in way to run as an OpenXR *overlay*: an app whose picture the runtime
 * draws on top of whatever VR game is running. The runtime side (Monado, which WiVRn and
 * GogglesXR are built on) offers this through the XR_EXTX_overlay extension. All it takes is
 * asking for that extension and adding one small structure when the session is created,
 * which is what this file does.
 *
 * It only acts when the environment variable GOGGLESXR_OVERLAY is set, so the same Godot
 * project still runs as a normal VR app without it. When the overlay session has been
 * requested it sets GOGGLESXR_OVERLAY_ACTIVE=1 for the dashboard's scripts to read.
 *
 * Written against Godot's plain C extension interface (include/gdextension_interface.h,
 * from godot-cpp 4.4) so it builds with one compiler command: see build.sh.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "gdextension_interface.h"

/* From the OpenXR specification (XR_EXTX_overlay). */
#define XR_TYPE_SESSION_CREATE_INFO_OVERLAY_EXTX 1000033000
typedef struct {
	int32_t type;
	const void *next;
	uint64_t createFlags;
	uint32_t sessionLayersPlacement; /* higher is drawn on top */
} XrSessionCreateInfoOverlayEXTX;

/* Method hashes from Godot 4.4's extension_api.json (class OpenXRExtensionWrapperExtension) */
#define HASH_GET_REQUESTED_EXTENSIONS 2382534195u
#define HASH_SET_SESSION_CREATE 3744713108u
#define HASH_REGISTER_EXTENSION_WRAPPER 3218959716u

/* Godot's built-in types, as opaque storage of the right size (64-bit, single precision) */
typedef struct { void *opaque; } GString;
typedef struct { void *opaque; } GStringName;
typedef struct { uint8_t opaque[24]; } GVariant;

static GDExtensionClassLibraryPtr library;
static GDExtensionInterfaceGetProcAddress get_proc;

static GDExtensionInterfaceStringNewWithLatin1Chars string_new;
static GDExtensionInterfaceStringNameNewWithLatin1Chars string_name_new;
static GDExtensionInterfaceVariantNewCopy variant_new_copy;
static GDExtensionInterfaceVariantDestroy variant_destroy;
static GDExtensionInterfaceDictionaryOperatorIndex dictionary_index;
static GDExtensionInterfaceObjectSetInstance object_set_instance;
static GDExtensionInterfaceClassdbConstructObject2 construct_object;
static GDExtensionVariantFromTypeConstructorFunc variant_from_string;
static GDExtensionVariantFromTypeConstructorFunc variant_from_int;
static GDExtensionPtrDestructor string_destroy;

static GStringName class_name;
static GStringName parent_name;

/* One wrapper exists for the life of the process */
static struct {
	uint8_t available; /* written by Godot (a C++ bool): does the runtime offer XR_EXTX_overlay? */
	XrSessionCreateInfoOverlayEXTX info;
	GDExtensionObjectPtr object;
} overlay;

static int overlay_wanted(void) {
	const char *value = getenv("GOGGLESXR_OVERLAY");
	return value != NULL && value[0] != '\0' && value[0] != '0';
}

/* Dictionary _get_requested_extensions(): extension name -> address of a bool for Godot to fill in */
static void get_requested_extensions(GDExtensionClassInstancePtr instance, const GDExtensionConstTypePtr *args, GDExtensionTypePtr r_dictionary) {
	(void)instance;
	(void)args;
	if (!overlay_wanted()) {
		return;
	}
	GString name;
	GVariant key, value;
	int64_t address = (int64_t)(intptr_t)&overlay.available;
	string_new(&name, "XR_EXTX_overlay");
	variant_from_string(&key, &name);
	variant_from_int(&value, &address);
	GDExtensionVariantPtr slot = dictionary_index(r_dictionary, &key);
	variant_destroy(slot);
	variant_new_copy(slot, &value);
	variant_destroy(&key);
	variant_destroy(&value);
	string_destroy(&name);
}

/* uint64 _set_session_create_and_get_next_pointer(void *next): chain our structure in front */
static void set_session_create(GDExtensionClassInstancePtr instance, const GDExtensionConstTypePtr *args, GDExtensionTypePtr r_pointer) {
	(void)instance;
	void *next = *(void *const *)args[0];
	if (!overlay_wanted() || !overlay.available) {
		if (overlay_wanted()) {
			fprintf(stderr, "GogglesXR overlay: the VR runtime doesn't offer XR_EXTX_overlay, running as a normal app\n");
		}
		*(int64_t *)r_pointer = (int64_t)(intptr_t)next;
		return;
	}
	overlay.info.type = XR_TYPE_SESSION_CREATE_INFO_OVERLAY_EXTX;
	overlay.info.next = next;
	overlay.info.createFlags = 0;
	overlay.info.sessionLayersPlacement = 10;
	setenv("GOGGLESXR_OVERLAY_ACTIVE", "1", 1);
	fprintf(stderr, "GogglesXR overlay: asking the VR runtime for an overlay session\n");
	*(int64_t *)r_pointer = (int64_t)(intptr_t)&overlay.info;
}

static GDExtensionClassCallVirtual get_virtual(void *class_userdata, GDExtensionConstStringNamePtr name, uint32_t hash) {
	(void)class_userdata;
	(void)name;
	if (hash == HASH_GET_REQUESTED_EXTENSIONS) {
		return get_requested_extensions;
	}
	if (hash == HASH_SET_SESSION_CREATE) {
		return set_session_create;
	}
	return NULL;
}

static GDExtensionObjectPtr create_instance(void *class_userdata, GDExtensionBool notify_postinitialize) {
	(void)class_userdata;
	(void)notify_postinitialize;
	GDExtensionObjectPtr object = construct_object(&parent_name);
	object_set_instance(object, &class_name, &overlay);
	return object;
}

static void free_instance(void *class_userdata, GDExtensionClassInstancePtr instance) {
	(void)class_userdata;
	(void)instance;
}

static void initialize(void *userdata, GDExtensionInitializationLevel level) {
	(void)userdata;
	/* Extension wrappers have to be registered before Godot starts OpenXR */
	if (level != GDEXTENSION_INITIALIZATION_CORE) {
		return;
	}
	string_new = (GDExtensionInterfaceStringNewWithLatin1Chars)get_proc("string_new_with_latin1_chars");
	string_name_new = (GDExtensionInterfaceStringNameNewWithLatin1Chars)get_proc("string_name_new_with_latin1_chars");
	variant_new_copy = (GDExtensionInterfaceVariantNewCopy)get_proc("variant_new_copy");
	variant_destroy = (GDExtensionInterfaceVariantDestroy)get_proc("variant_destroy");
	dictionary_index = (GDExtensionInterfaceDictionaryOperatorIndex)get_proc("dictionary_operator_index");
	object_set_instance = (GDExtensionInterfaceObjectSetInstance)get_proc("object_set_instance");
	construct_object = (GDExtensionInterfaceClassdbConstructObject2)get_proc("classdb_construct_object2");
	GDExtensionInterfaceGetVariantFromTypeConstructor from_type =
			(GDExtensionInterfaceGetVariantFromTypeConstructor)get_proc("get_variant_from_type_constructor");
	GDExtensionInterfaceVariantGetPtrDestructor ptr_destructor =
			(GDExtensionInterfaceVariantGetPtrDestructor)get_proc("variant_get_ptr_destructor");
	GDExtensionInterfaceClassdbRegisterExtensionClass4 register_class =
			(GDExtensionInterfaceClassdbRegisterExtensionClass4)get_proc("classdb_register_extension_class4");
	GDExtensionInterfaceClassdbGetMethodBind get_method_bind =
			(GDExtensionInterfaceClassdbGetMethodBind)get_proc("classdb_get_method_bind");
	GDExtensionInterfaceObjectMethodBindPtrcall ptrcall =
			(GDExtensionInterfaceObjectMethodBindPtrcall)get_proc("object_method_bind_ptrcall");
	if (!string_new || !string_name_new || !variant_new_copy || !variant_destroy || !dictionary_index ||
			!object_set_instance || !construct_object || !from_type || !ptr_destructor || !register_class ||
			!get_method_bind || !ptrcall) {
		fprintf(stderr, "GogglesXR overlay: this Godot version lacks functions the extension needs\n");
		return;
	}
	variant_from_string = from_type(GDEXTENSION_VARIANT_TYPE_STRING);
	variant_from_int = from_type(GDEXTENSION_VARIANT_TYPE_INT);
	string_destroy = ptr_destructor(GDEXTENSION_VARIANT_TYPE_STRING);

	GStringName method;
	string_name_new(&class_name, "GogglesXROverlay", 1);
	string_name_new(&parent_name, "OpenXRExtensionWrapperExtension", 1);
	string_name_new(&method, "register_extension_wrapper", 1);

	GDExtensionMethodBindPtr register_wrapper = get_method_bind(&parent_name, &method, HASH_REGISTER_EXTENSION_WRAPPER);
	if (!register_wrapper) {
		fprintf(stderr, "GogglesXR overlay: this Godot has no OpenXR extension support\n");
		return;
	}

	GDExtensionClassCreationInfo4 info = { 0 };
	info.is_exposed = 0;
	info.is_runtime = 1;
	info.create_instance_func = create_instance;
	info.free_instance_func = free_instance;
	info.get_virtual_func = get_virtual;
	register_class(library, &class_name, &parent_name, &info);

	overlay.object = construct_object(&class_name);
	if (overlay.object) {
		ptrcall(register_wrapper, overlay.object, NULL, NULL);
	}
}

static void deinitialize(void *userdata, GDExtensionInitializationLevel level) {
	/* The wrapper stays registered with Godot's OpenXR code until the process ends */
	(void)userdata;
	(void)level;
}

__attribute__((visibility("default"))) GDExtensionBool gogglesxr_overlay_init(GDExtensionInterfaceGetProcAddress p_get_proc_address,
		GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
	get_proc = p_get_proc_address;
	library = p_library;
	r_initialization->minimum_initialization_level = GDEXTENSION_INITIALIZATION_CORE;
	r_initialization->userdata = NULL;
	r_initialization->initialize = initialize;
	r_initialization->deinitialize = deinitialize;
	return 1;
}
