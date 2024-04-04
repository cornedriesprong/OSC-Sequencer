//
//  CPSequencer.h
//  CPSequencer
//
//  Created by Corné on 16/07/2020.
//  Copyright © 2020 cp3.io. All rights reserved.
//

#import <AudioToolbox/AudioToolbox.h>
#import <os/lock.h>
#import "TPCircularBuffer.h"

#define NOTE_ON             0x90
#define NOTE_OFF            0x80
#define CC                  0xB0
#define PITCH_BEND          0xE0
#define PROGRAM_CHANGE      0xE0
#define MIDI_CLOCK          0xF8
#define MIDI_CLOCK_START    0xFA
#define MIDI_CLOCK_CONTINUE 0xFA
#define MIDI_CLOCK_STOP     0xFC
#define PPQ                 96
#define NOTE_CAPACITY       256
#define BUFFER_LENGTH       1048576
#define MIDI_PACKET_SIZE    16
#define SEQUENCE_COUNT      7       // bd, sd, hh, pc, bass, chords, lead
#define MAX_EVENT_COUNT     2048

typedef struct SequencerSettings {
    double tempo;
    double sampleRate;
    const UInt32 frameCount;
} SequencerSettings;

typedef struct MIDIEvent {
    double beatTime;
    uint8_t status;
    int8_t data1;
    int8_t data2;
    double duration;   // only relevant for note events
    int chance;
    int skip;
    int skipCount;
    int offset;
    int destination;
    int channel;
    int sequenceIndex;
    bool isRatchet;     // used to determine if event should be affected by the probability of the preceding
    bool queued;
} MIDIEvent;

typedef struct MIDISequence {
    double length;
    int eventCount;
    double playbackRatio;
    struct MIDIEvent events[MAX_EVENT_COUNT];
} MIDISequence;

typedef struct PlayingNote {
    double beatTime;
    int pitch;
    int channel;
    int dest;
    int sequence;
    bool stopped;
} PlayingNote;

typedef void (*callback_t)(const double beat,
                           const int sequenceIndex,
                           void * __nullable refCon);

#ifdef __cplusplus
#include <atomic>
#include <vector>

class CPSequencer {
private:
    TPCircularBuffer fifoBuffer;
    struct os_unfair_lock_s lock;
    
    // nb: these are owned by the audio thread
    int previousSubtick = -1;
    int previousSegment = -1;
    bool soloSequences[SEQUENCE_COUNT];
    bool muteSequences[SEQUENCE_COUNT];
    int64_t previousTimestamp = 0;
    callback_t callback;
    void *callbackRefCon;
    MIDISequence sequences[SEQUENCE_COUNT];
    int prevBeat[SEQUENCE_COUNT];
    std::vector<PlayingNote> playingNotes;
    std::atomic<float> swing;
    std::atomic<bool> MIDIClockOn;
    bool sendMIDIClockStart = true;
    bool chanceDidPlay = true;
    
    void getMidiEventsFromFIFOBuffer();
    void stopPlayingNotes(MIDIPacket *midi, AUEventSampleTime now, double beatPosition, SequencerSettings settings);
    void addPlayingNoteToMidiData(char status, AUEventSampleTime offset, PlayingNote *note, MIDIPacket *midi);
    void addEventToMidiData(char status, AUEventSampleTime offset, MIDIEvent *ev, MIDIPacket *midiData);
    void scheduleMIDIClock(uint8_t subtick, MIDIPacket *midi);
    void scheduleEventsForNextSegment(const double beatPosition);
    
public:
    CPSequencer(callback_t __nullable cb, void * __nullable refCon);
    void addMidiEvent(MIDIEvent event);
    void deleteMidiEvent(MIDIEvent event);
    void clearSequence(int sequenceIndex);
    void changeSequenceLength(float length, int sequenceIndex);
    void changeStepDivision(double stepDivision, int sequenceIndex);
    void setSwing(float swing);
    void setMute(bool isOn, int sequenceIndex);
    void setSolo(bool isOn, int sequenceIndex);
    void clearBuffers(MIDIPacket midiData[MIDI_PACKET_SIZE][8]);
    void stopSequencer();
    void setMIDIClockOn(bool isOn);
    
    void renderTimeline(const AUEventSampleTime now,
                        SequencerSettings settings,
                        const double beatPosition,
                        MIDIPacket midiData[MIDI_PACKET_SIZE][8]);
};

#endif
