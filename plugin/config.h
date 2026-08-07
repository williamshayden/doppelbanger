#pragma once

#define SAMPLE_TYPE_FLOAT

#define PLUG_NAME "Doppelbanger"
#define PLUG_MFR "Goblin City Records"
#define PLUG_VERSION_HEX 0x00010000
#define PLUG_VERSION_STR "1.0.0"
#define PLUG_UNIQUE_ID 'DBng'
// This ID contributes to the stable VST3 class IDs and must not change.
#define PLUG_MFR_ID 'WHyd'
#define PLUG_URL_STR "https://github.com/williamshayden/doppelbanger"
#define PLUG_EMAIL_STR ""
#define PLUG_COPYRIGHT_STR "Copyright 2026 Goblin City Records"
#define PLUG_CLASS_NAME Doppelbanger

#define BUNDLE_NAME "Doppelbanger"
#define BUNDLE_MFR "GoblinCityRecords"
#define BUNDLE_DOMAIN "com"
#define SHARED_RESOURCES_SUBPATH "Doppelbanger"

#define PLUG_CHANNEL_IO "2-2"
#define PLUG_LATENCY 0
#define PLUG_TYPE 0
#define PLUG_DOES_MIDI_IN 0
#define PLUG_DOES_MIDI_OUT 0
#define PLUG_DOES_MPE 0
#define PLUG_DOES_STATE_CHUNKS 1
#ifndef PLUG_HAS_UI
#define PLUG_HAS_UI 1
#endif
#define PLUG_WIDTH 760
#define PLUG_HEIGHT 500
#define PLUG_FPS 30
#define PLUG_SHARED_RESOURCES 0
#define PLUG_HOST_RESIZE 0

#define VST3_SUBCATEGORY "Fx|Mastering"
